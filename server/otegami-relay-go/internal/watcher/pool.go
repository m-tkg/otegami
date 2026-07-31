// Package watcher runs one IMAP connection per watch, IDLE-ing (or
// STATUS-polling, for servers without IDLE) for new mail and firing a push
// through push.Sender when UIDNEXT advances — mirrors WatcherPool.swift
// (server/otegami-relay/Sources/OtegamiRelay/Watcher/WatcherPool.swift).
//
// Watch goroutines are tracked in a mutex-guarded map so the HTTP routes
// can call AddWatch/RemoveWatch the moment a watch is created/deleted via
// the API, without waiting for any reconciliation pass. RemoveWatch
// cancels the watch's context, which (via context.AfterFunc closing the
// IMAP connection) promptly unblocks a mid-IDLE read — the Go equivalent
// of Swift Task cancellation waking LineBuffer.
package watcher

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/m-tkg/otegami-relay-go/internal/api"
	"github.com/m-tkg/otegami-relay-go/internal/imapclient"
	"github.com/m-tkg/otegami-relay-go/internal/oauth"
	"github.com/m-tkg/otegami-relay-go/internal/push"
	"github.com/m-tkg/otegami-relay-go/internal/security"
	"github.com/m-tkg/otegami-relay-go/internal/store"
)

// maxConsecutiveAuthFailures mirrors WatcherPool.maxConsecutiveAuthFailures
// — consecutive login failures at which a watch gives up entirely rather
// than continuing to retry (avoids hammering an IMAP server with
// credentials that are simply wrong). Only applies to a watch whose
// credential has *never* authenticated successfully (WatchRecord
// .LastConnectedAt == nil) — see classifyAuthFailure's caller in
// connectAndWatch and defaultAuthFailureRetryInterval's doc comment for the
// watch that has succeeded before.
const maxConsecutiveAuthFailures = 3

// defaultAuthFailureRetryInterval / defaultAuthFailureRetryCap (Task #187):
// how long a watch waits before retrying after an IMAP
// AUTHENTICATIONFAILED-shaped rejection, for a watch whose credential has
// authenticated successfully at least once before
// (WatchRecord.LastConnectedAt != nil) — see connectAndWatch.
//
// Real-world trigger: Yahoo Japan (imap.mail.yahoo.co.jp) accounts observed
// failing auth intermittently with the *same* credential that had
// connected successfully earlier the same day. The relay's own tagged-
// response logging (commandFailedServerResponse) captured the server's
// exact reply: `A1 NO [AUTHENTICATIONFAILED] Incorrect username or
// password.` — not a `[LIMIT]`/`[UNAVAILABLE]`-shaped rate-limit response
// (Task #206 later observed exactly that shape, but on STATUS, not LOGIN —
// see isRateLimited), but a stored credential that worked minutes earlier
// cannot have simply become wrong.
// Yahoo's own support guidance describes repeated authentication failures
// triggering a temporary account lock, without stating its duration:
// https://note.chiilabo.jp/2026-04/yahoo-japan-imap-external-access-change/
//
// No published duration exists to anchor this precisely, so 30 minutes is
// chosen as comfortably longer than the "tens of minutes" lockout windows
// commonly described for this class of protection, while still recovering
// within the same day — and it matches this codebase's own existing
// precedent for "back off a failed operation, cap the wait, try again
// later" at this exact timescale: OpQueueProcessor.backoffCap (Swift side,
// `packages/OtegamiKit/Sources/SyncEngine/OpQueueProcessor.swift`) already
// caps its retry backoff at 30 minutes for the same class of problem
// (a stuck operation that shouldn't be hammered). Doubles on further
// consecutive failures (mirroring the connection-error backoff below) up
// to defaultAuthFailureRetryCap.
//
// **The cap was 6 hours and is now 1 hour**, because the original reasoning
// optimised the wrong side of the trade-off. The doubling exists so a
// credential that is genuinely and permanently wrong isn't re-probed
// forever; its cost is recovery latency once what expired is the *lock*,
// not the credential. Production showed that cost is the one that bites: a
// Yahoo account sat unreachable for hours after Task #201 cut the login
// volume, because attempt N+1 was scheduled hours out even though the lock
// itself clears on the order of minutes (that same account had
// authenticated successfully earlier the same hour).
//
// At a 1-hour cap the worst case is 24 login attempts per day per watch.
// Against the ~576/day that caused the lockout in the first place, that is
// nowhere near enough volume to provoke anything, while bounding "the lock
// expired but we haven't noticed" to an hour instead of six. A deployment
// that needs the long tail back should raise this via Options rather than
// changing the default.
//
// Both are Options fields (not raw constants) so tests can drive them down
// to milliseconds — same "Options carries the tunable, New() supplies the
// production default" shape as IdleMaxWait/PollInterval/ConnectTimeout.
const (
	defaultAuthFailureRetryInterval = 30 * time.Minute
	defaultAuthFailureRetryCap      = 1 * time.Hour
)

// errMissingOAuthProvider mirrors WatchAuthenticationError
// .missingOAuthProvider — a watch record inconsistent with its own
// authType (.oauth with no provider). The routes validate this at creation
// time, so reaching it means a pre-validation row or a bug; retrying can
// never fix data that's wrong at rest.
var errMissingOAuthProvider = errors.New("oauth watch has no provider")

// Options mirrors WatcherPool.init's tunable parameters. Zero values get
// the production defaults; tests drive them down to milliseconds.
type Options struct {
	// IdleMaxWait: RFC 2177 wants IDLE reissued at least every 29
	// minutes (the default).
	IdleMaxWait time.Duration
	// PollInterval: the STATUS-polling fallback interval for servers
	// without IDLE (default 5 minutes).
	PollInterval time.Duration
	// PollKeepAliveInterval (Task #201): how often a NOOP is sent during
	// a PollInterval wait to keep the connection from being dropped for
	// inactivity before the next STATUS check — see pollWait's doc
	// comment for why this exists and how the default was chosen.
	// Default 2 minutes.
	PollKeepAliveInterval time.Duration
	// NetworkPolicy is re-validated on every (re)connect, not just once
	// at watch creation (CLAUDE-SECURITY F2). Zero value is NOT strict —
	// main() must pass the configured policy explicitly; tests that dial
	// loopback pass security.PermissiveForTesting().
	NetworkPolicy security.NetworkPolicy
	// ConnectTimeout for the TCP/TLS dial (default 15s, matching
	// MinimalIMAPClient.connect's timeoutSeconds).
	ConnectTimeout time.Duration
	// OAuth exchanges a .oauth watch's stored refresh token for an access
	// token right before AUTHENTICATE XOAUTH2 (Task #175). Defaults to
	// oauth.Unconfigured (always fails, classified as connectionError) —
	// harmless for .password-only deployments.
	OAuth oauth.TokenExchanger
	// AuthFailureRetryInterval / AuthFailureRetryCap (Task #187): see
	// defaultAuthFailureRetryInterval's doc comment. Defaults to 30
	// minutes / 6 hours; tests drive these down to milliseconds.
	AuthFailureRetryInterval time.Duration
	AuthFailureRetryCap      time.Duration
	// RateLimitInitialWait / RateLimitWaitCap (Task #206): how long a
	// watch waits, on the same still-authenticated connection, after the
	// server answers STATUS with a `[LIMIT]` response code before trying
	// again — see isRateLimited's doc comment for why this must never
	// become a reconnect. Doubles on consecutive hits (mirroring every
	// other backoff in this file), resetting the moment a STATUS
	// succeeds again.
	//
	// No published rate-limit-recovery duration exists for Yahoo Japan's
	// IMAP (unlike the auth-lockout case, where Yahoo's own support
	// guidance describes "tens of minutes" — see
	// defaultAuthFailureRetryInterval's doc comment). The only real
	// evidence available (docs/architecture.md "e." Task #206) is that
	// STATUS was already being called no more than once per PollInterval
	// (5 minutes) when the limit hit, so waiting less than that before
	// retrying can't be justified by anything measured.
	// RateLimitInitialWait therefore defaults to Options.PollInterval
	// itself rather than an independently-guessed number — retrying "not
	// appreciably faster than the cadence that was already being rate
	// limited" is the most conservative response that doesn't require a
	// new, unmeasured timescale. The cap reuses this file's existing
	// 30-minute precedent for "temporary block, unknown duration" (see
	// defaultAuthFailureRetryInterval).
	RateLimitInitialWait time.Duration
	RateLimitWaitCap     time.Duration
}

// Pool mirrors WatcherPool.
type Pool struct {
	store  *store.Store
	sender push.Sender
	logger *slog.Logger
	opts   Options

	rootCtx    context.Context
	rootCancel context.CancelFunc

	mu      sync.Mutex
	cancels map[string]context.CancelFunc
	wg      sync.WaitGroup
}

// New builds a Pool. Watches added via AddWatch run until RemoveWatch,
// Stop, or their loop gives up (auth failures).
func New(s *store.Store, sender push.Sender, logger *slog.Logger, opts Options) *Pool {
	if opts.IdleMaxWait == 0 {
		opts.IdleMaxWait = 29 * time.Minute
	}
	if opts.PollInterval == 0 {
		opts.PollInterval = 5 * time.Minute
	}
	if opts.PollKeepAliveInterval == 0 {
		opts.PollKeepAliveInterval = 45 * time.Second
	}
	if opts.ConnectTimeout == 0 {
		opts.ConnectTimeout = 15 * time.Second
	}
	if opts.OAuth == nil {
		opts.OAuth = oauth.Unconfigured{}
	}
	if opts.AuthFailureRetryInterval == 0 {
		opts.AuthFailureRetryInterval = defaultAuthFailureRetryInterval
	}
	if opts.AuthFailureRetryCap == 0 {
		opts.AuthFailureRetryCap = defaultAuthFailureRetryCap
	}
	if opts.RateLimitInitialWait == 0 {
		// Deliberately reuses the (already-defaulted, above) PollInterval
		// rather than an independent constant — see the field's doc
		// comment.
		opts.RateLimitInitialWait = opts.PollInterval
	}
	if opts.RateLimitWaitCap == 0 {
		opts.RateLimitWaitCap = 30 * time.Minute
	}
	rootCtx, rootCancel := context.WithCancel(context.Background())
	return &Pool{
		store:      s,
		sender:     sender,
		logger:     logger,
		opts:       opts,
		rootCtx:    rootCtx,
		rootCancel: rootCancel,
		cancels:    map[string]context.CancelFunc{},
	}
}

// Run mirrors WatcherPool.run() (its ServiceLifecycle entry point): starts
// a loop for every persisted watch, then blocks until ctx is cancelled
// (graceful shutdown), stopping every loop before returning.
func (p *Pool) Run(ctx context.Context) error {
	records, err := p.store.ListWatches(ctx)
	if err != nil {
		p.logger.Warn("could not list existing watches at startup", "error", err.Error())
		records = nil
	}
	for _, record := range records {
		p.AddWatch(record.ID)
	}
	p.logger.Info("WatcherPool started", "watchCount", len(records))
	<-ctx.Done()
	p.Stop()
	return nil
}

// Stop cancels every watch loop and waits for them to exit.
func (p *Pool) Stop() {
	p.rootCancel()
	p.mu.Lock()
	for _, cancel := range p.cancels {
		cancel()
	}
	p.cancels = map[string]context.CancelFunc{}
	p.mu.Unlock()
	p.wg.Wait()
}

// AddWatch mirrors WatcherPool.addWatch(id:) — called from the HTTP routes
// the moment a watch is created. A no-op if the watch already has a loop.
func (p *Pool) AddWatch(id string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if _, exists := p.cancels[id]; exists {
		return
	}
	if p.rootCtx.Err() != nil {
		return // pool already stopped
	}
	ctx, cancel := context.WithCancel(p.rootCtx)
	p.cancels[id] = cancel
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		defer func() {
			p.mu.Lock()
			if c, ok := p.cancels[id]; ok {
				c()
				delete(p.cancels, id)
			}
			p.mu.Unlock()
		}()
		p.runWatchLoop(ctx, id)
	}()
}

// RemoveWatch mirrors WatcherPool.removeWatch(id:) — called from the HTTP
// routes the moment a watch is deleted. Cancelling the context promptly
// closes the loop's IMAP connection (see runWatchLoop's AfterFunc).
func (p *Pool) RemoveWatch(id string) {
	p.mu.Lock()
	cancel, ok := p.cancels[id]
	if ok {
		delete(p.cancels, id)
	}
	p.mu.Unlock()
	if ok {
		cancel()
	}
}

// sleepCtx sleeps for d or until ctx is cancelled, whichever comes first.
func sleepCtx(ctx context.Context, d time.Duration) {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-timer.C:
	case <-ctx.Done():
	}
}

// runWatchLoop mirrors WatcherPool.runWatchLoop(watchId:) — see that
// method for the full narrative; the control flow here is kept
// deliberately parallel (auth failures counted and classified separately
// from connection errors; consecutiveAuthFailures only reset by a
// successful authentication; backoff doubling capped at 5 minutes).
func (p *Pool) runWatchLoop(ctx context.Context, watchID string) {
	consecutiveAuthFailures := 0
	backoff := 2 * time.Second
	// Task #187: a separate, much longer backoff for auth failures on a
	// watch whose credential has succeeded before — see
	// defaultAuthFailureRetryInterval's doc comment. Kept independent of
	// `backoff` (the connection-error track) so a watch that alternates
	// between the two failure kinds doesn't have one contaminate the
	// other's timescale.
	authBackoff := p.opts.AuthFailureRetryInterval

	for ctx.Err() == nil {
		record, err := p.store.Watch(ctx, watchID)
		if err != nil || record == nil {
			p.logger.Info("watch no longer exists, stopping", "watchId", watchID)
			return
		}

		client := imapclient.New()
		// Promptly tear the connection down the moment this watch's
		// context is cancelled (RemoveWatch / pool shutdown) — closing the
		// conn unblocks any in-flight read, including a mid-IDLE one.
		stopAfterFunc := context.AfterFunc(ctx, func() { _ = client.Close() })

		err = p.connectAndWatch(ctx, client, record, &consecutiveAuthFailures, &backoff, &authBackoff)
		stopAfterFunc()
		_ = client.Close()

		switch {
		case ctx.Err() != nil:
			return
		case err == nil:
			// connectAndWatch only returns nil when it decided the loop
			// should keep going immediately (post-auth-failure retry with
			// its own backoff already applied).
			continue
		case errors.Is(err, errWatchStopped):
			return
		default:
			p.logger.Warn("watch connection error, reconnecting",
				"watchId", watchID, "error", push.SanitizeForLog(err.Error()))
			// Task #173: recorded for display only — never stopping. A
			// connection/network blip is expected to recover on its own.
			_ = p.store.RecordWatchError(ctx, watchID, api.ErrorKindConnectionError, false)
			sleepCtx(ctx, backoff)
			backoff = minDuration(backoff*2, 5*time.Minute)
		}
	}
}

// errWatchStopped signals runWatchLoop that the watch gave up permanently
// (auth failures) and the loop must exit rather than reconnect.
var errWatchStopped = errors.New("watch stopped")

// connectAndWatch performs one connection lifetime: connect, authenticate,
// SELECT baseline, then IDLE/poll until an error or cancellation.
// Returns:
//   - errWatchStopped: give up permanently (already persisted).
//   - nil: an auth failure was handled (recorded + backoff slept) and the
//     outer loop should retry immediately.
//   - any other error: a connection-level failure the outer loop records
//     and retries with backoff.
func (p *Pool) connectAndWatch(
	ctx context.Context,
	client *imapclient.Client,
	record *store.WatchRecord,
	consecutiveAuthFailures *int,
	backoff *time.Duration,
	authBackoff *time.Duration,
) error {
	if err := client.Connect(record.ImapHost, record.ImapPort, record.ImapUseTLS, p.opts.ConnectTimeout, p.opts.NetworkPolicy); err != nil {
		return err
	}

	if err := p.authenticate(ctx, client, record); err != nil {
		_ = client.Close()
		if ctx.Err() != nil {
			return ctx.Err()
		}
		*consecutiveAuthFailures++
		kind, stopsImmediately := classifyAuthFailure(err)
		p.logger.Warn("watch authentication failed",
			"watchId", record.ID,
			"attempt", *consecutiveAuthFailures,
			"kind", string(kind),
			// Task #187: the server's own tagged response, so a rate limit
			// or a policy block can be told apart from an actually-wrong
			// password. Yahoo Japan accounts fail here intermittently and
			// the collapsed "authFailure" classification hid why. A tagged
			// response never echoes the command, so no credential can reach
			// the log this way; SanitizeForLog is the same F16 backstop used
			// for every other attacker-influenced string.
			"serverResponse", commandFailedServerResponse(err),
		)
		// Task #187: a watch whose credential has authenticated
		// successfully before (WatchRecord.LastConnectedAt != nil) never
		// gives up on a plain "wrong password"-shaped rejection (kind ==
		// AuthFailure, stopsImmediately == false) — a credential that
		// worked minutes/hours ago cannot have simply become wrong, so
		// this is treated as a possible temporary lock (see
		// defaultAuthFailureRetryInterval's doc comment) rather than
		// confirmed-invalid credentials. `stopsImmediately` cases (dead
		// OAuth refresh token, missing provider — structurally
		// unrecoverable, nothing to do with a lock) always still stop
		// regardless of history.
		hasSucceededBefore := record.LastConnectedAt != nil
		givingUp := shouldGiveUpAfterAuthFailure(stopsImmediately, hasSucceededBefore, *consecutiveAuthFailures)
		// Task #173: persist this so GET /v1/watches can tell the app
		// which account's watch actually stopped. Task #187: `givingUp ==
		// false` here also covers "proven-good credential, keep retrying
		// at a long interval" — status stays whatever MarkWatchConnected
		// last set (never forced to 'stopped'), so the watch resumes on
		// its own the moment the lock clears, no manual re-registration
		// needed.
		_ = p.store.RecordWatchError(ctx, record.ID, kind, givingUp)
		if givingUp {
			p.logger.Error("watch stopped after authentication failure",
				"watchId", record.ID, "kind", string(kind))
			return errWatchStopped
		}
		if !stopsImmediately && kind == api.ErrorKindAuthFailure && hasSucceededBefore {
			sleepCtx(ctx, *authBackoff)
			*authBackoff = minDuration(*authBackoff*2, p.opts.AuthFailureRetryCap)
			return nil
		}
		sleepCtx(ctx, *backoff)
		*backoff = minDuration(*backoff*2, 5*time.Minute)
		return nil
	}

	*consecutiveAuthFailures = 0
	*backoff = 2 * time.Second
	*authBackoff = p.opts.AuthFailureRetryInterval
	_ = p.store.MarkWatchConnected(ctx, record.ID)

	selectResult, err := client.Select(record.Mailbox)
	if err != nil {
		return err
	}
	var baselineUIDNext int
	if selectResult.UidNext != nil {
		baselineUIDNext = *selectResult.UidNext
	} else if fromStatus, statusErr := client.StatusUIDNext(record.Mailbox); statusErr == nil {
		baselineUIDNext = fromStatus
	}
	idleSupported, err := client.CapabilitiesIncludeIdle()
	if err != nil {
		idleSupported = false
	}

	p.logger.Info("watch connected",
		"watchId", record.ID, "idle", idleSupported, "uidNext", baselineUIDNext)

	// Task #206: how long to wait, on this same connection, the next time
	// STATUS comes back `[LIMIT]` — see isRateLimited's doc comment. Reset
	// to the initial value after every STATUS that doesn't hit the limit,
	// so one isolated blip doesn't permanently slow this watch down.
	rateLimitWait := p.opts.RateLimitInitialWait

	for ctx.Err() == nil {
		if idleSupported {
			gotExists, err := client.Idle(record.Mailbox, p.opts.IdleMaxWait)
			if err != nil {
				return err
			}
			if !gotExists {
				continue
			}
		} else {
			if err := p.pollWait(ctx, client); err != nil {
				return err
			}
			if ctx.Err() != nil {
				return ctx.Err()
			}
		}

		newUIDNext, err := client.StatusUIDNext(record.Mailbox)
		if err != nil {
			if isRateLimited(err) {
				// Task #206 core fix: the connection is still alive and
				// authenticated — a `[LIMIT]` response is the server
				// asking us to slow down, not a connection failure.
				// Falling through to the generic `return err` below would
				// have the caller (runWatchLoop) close this perfectly
				// good connection and reconnect, forcing a fresh LOGIN —
				// which is exactly what turned this rate limit into an
				// hours-long auth lockout in production (see
				// isRateLimited's doc comment). Wait it out right here and
				// resume on the same connection instead.
				p.logger.Warn("watch rate limited by server, waiting on the same connection instead of reconnecting",
					"watchId", record.ID, "wait", rateLimitWait.String(),
					"serverResponse", commandFailedServerResponse(err))
				// Recorded for display only (mirrors the plain
				// connection-error path just below this loop) —
				// `stopping=false` never touches Status, so an
				// already-`.active` watch keeps showing active while this
				// resolves on its own.
				_ = p.store.RecordWatchError(ctx, record.ID, api.ErrorKindConnectionError, false)
				sleepCtx(ctx, rateLimitWait)
				if ctx.Err() != nil {
					return ctx.Err()
				}
				rateLimitWait = minDuration(rateLimitWait*2, p.opts.RateLimitWaitCap)
				continue
			}
			return err
		}
		rateLimitWait = p.opts.RateLimitInitialWait
		if newUIDNext > baselineUIDNext {
			baselineUIDNext = newUIDNext
			p.fire(ctx, record, newUIDNext)
		}
	}
	return ctx.Err()
}

// pollWait waits out one PollInterval before the next STATUS check (the
// non-IDLE polling fallback used by servers that don't support IDLE — see
// connectAndWatch's "idle" log field), sending an IMAP NOOP every
// PollKeepAliveInterval along the way so the connection sees regular
// traffic instead of going quiet for the full PollInterval.
//
// Why this exists (Task #201): production logs showed Yahoo Japan
// (imap.mail.yahoo.co.jp, which answers CAPABILITY without IDLE, so every
// watch on it takes this branch) severing the connection mid-wait with
// "write: broken pipe" well before a single 5-minute PollInterval
// elapsed. connectAndWatch's outer loop treats that as a plain connection
// error and reconnects — which means a fresh LOGIN — so every watch on
// Yahoo was re-authenticating roughly every 5 minutes around the clock
// (doubled per account with two devices registered). Repeated LOGINs from
// the same IP is exactly the pattern Yahoo's own abuse protection reacts
// to with temporary lockouts, which is what Task #187's "[AUTHENTICATION
// FAILED] Incorrect username or password" reports actually were — not a
// wrong password, since the same credential kept succeeding again minutes
// later.
//
// The interval was first set to 2 minutes based on third-party reports
// (e.g. Mozilla bug 468490) describing Yahoo IMAP as dropping idle
// connections after roughly 5 minutes. **Production disproved that.** With
// a 2-minute keepalive, a production deployment logged:
//
//	00:35:15  watch connected            (LOGIN succeeded)
//	00:37:15  IMAP connection closed unexpectedly
//
// — dead at exactly the 2-minute mark, i.e. the NOOP found a connection the
// server had already dropped. Yahoo's real idle timeout is therefore well
// under 2 minutes, and the 2-minute setting actively made things worse: it
// reconnected (and re-LOGINed) every 2 minutes instead of the previous 5,
// raising login volume from ~288/day to ~720/day on the very account whose
// lockout this task exists to stop.
//
// The default is now 45 seconds, chosen from that measurement rather than
// from reports: comfortably under the observed sub-2-minute threshold, with
// enough margin that a slow round-trip doesn't straddle it. A NOOP is a
// single cheap command — 80/hour per watch is negligible next to the full
// TCP+TLS handshake and LOGIN it replaces. If production still shows
// "connection closed unexpectedly" at the 45-second mark, shorten this
// further; the log line above is exactly the evidence to look for.
//
// IDLE-capable servers (iCloud, Gmail, Outlook) never take this branch —
// they block in Idle() instead, bounded by IdleMaxWait (29 minutes, RFC
// 2177's own recommended re-issue interval) — so they're unaffected by
// PollKeepAliveInterval entirely.
func (p *Pool) pollWait(ctx context.Context, client *imapclient.Client) error {
	remaining := p.opts.PollInterval
	for remaining > 0 {
		step := p.opts.PollKeepAliveInterval
		if step <= 0 || step > remaining {
			step = remaining
		}
		sleepCtx(ctx, step)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		remaining -= step
		if remaining > 0 {
			if err := client.Noop(); err != nil {
				return err
			}
		}
	}
	return nil
}

// authenticate mirrors runWatchLoop's authType switch: plain LOGIN for
// .password, token exchange + XOAUTH2 for .oauth (Task #175 —
// record.Secret is a refresh token there, never an IMAP password; the
// short-lived access token is never persisted).
func (p *Pool) authenticate(ctx context.Context, client *imapclient.Client, record *store.WatchRecord) error {
	switch record.AuthType {
	case api.WatchAuthPassword:
		return client.Login(record.ImapUsername, record.Secret)
	case api.WatchAuthOAuth:
		if record.Provider == nil {
			return errMissingOAuthProvider
		}
		accessToken, err := p.opts.OAuth.AccessToken(ctx, *record.Provider, record.Secret)
		if err != nil {
			return err
		}
		return client.AuthenticateXOAuth2(record.ImapUsername, accessToken)
	default:
		// A row whose authType this binary doesn't recognize (raw DB edit
		// or rollback skew) — same "wrong at rest, retrying never fixes
		// it" posture as errMissingOAuthProvider.
		return errMissingOAuthProvider
	}
}

// fire mirrors WatcherPool.fire(record:uidNext:).
func (p *Pool) fire(ctx context.Context, record *store.WatchRecord, uidNext int) {
	target, err := p.store.PushTarget(ctx, record.DeviceID)
	if err != nil || target == nil {
		p.logger.Debug("watch fired but device has no push token yet", "watchId", record.ID)
		return
	}
	err = p.sender.Send(ctx, target.ApnsToken, target.Environment, api.PushNotificationPayload{
		AccountID: record.AccountID,
		UidNext:   uidNext,
	})
	if err != nil {
		p.logger.Warn("push send failed",
			"watchId", record.ID, "error", push.SanitizeForLog(err.Error()))
	}
}

// shouldGiveUpAfterAuthFailure (Task #187) decides whether a watch
// permanently stops (status -> 'stopped', requires manual re-registration)
// after this authentication failure, or keeps retrying. Pulled out as its
// own pure function — no *Pool, no store, no IMAP client — so the
// success-history judgment itself is unit-testable without spinning up a
// fake IMAP server (see pool_test.go's TestShouldGiveUpAfterAuthFailure).
//
//   - stopsImmediately (from classifyAuthFailure: a dead OAuth refresh
//     token, or a locally-detected configuration problem) always gives up
//     on the first occurrence, regardless of history — retrying either can
//     never succeed.
//   - Otherwise, a credential that has authenticated successfully before
//     (hasSucceededBefore) never gives up — see
//     defaultAuthFailureRetryInterval's doc comment for why a "wrong
//     password"-shaped rejection from a proven-good credential is treated
//     as a possible temporary lock, not confirmed-invalid credentials.
//   - A credential with no success on record gives up after
//     maxConsecutiveAuthFailures — unchanged pre-Task-#187 behavior, since
//     there's no prior success to make "this is just a lock" plausible.
func shouldGiveUpAfterAuthFailure(stopsImmediately, hasSucceededBefore bool, consecutiveAuthFailures int) bool {
	if stopsImmediately {
		return true
	}
	if hasSucceededBefore {
		return false
	}
	return consecutiveAuthFailures >= maxConsecutiveAuthFailures
}

// classifyAuthFailure mirrors WatcherPool.classifyAuthFailure(_:) — which
// api.WatchErrorKind to persist, and whether to give up on the very first
// occurrence rather than waiting for maxConsecutiveAuthFailures.
func classifyAuthFailure(err error) (kind api.WatchErrorKind, stopsImmediately bool) {
	if errors.Is(err, oauth.ErrInvalidGrant) {
		// The refresh token itself is dead — no amount of retrying will
		// ever succeed again without a fresh one from the app.
		return api.ErrorKindOAuthTokenExpired, true
	}
	var missingClientID *oauth.MissingClientIDError
	var requestFailed *oauth.TokenRequestFailedError
	var network *oauth.NetworkError
	if errors.As(err, &missingClientID) || errors.As(err, &requestFailed) ||
		errors.As(err, &network) || errors.Is(err, oauth.ErrInvalidResponse) {
		// Transient (network hiccup, endpoint outage) or an operator
		// configuration gap — retried like a connection error before
		// giving up, rather than stopping instantly.
		return api.ErrorKindConnectionError, false
	}
	if errors.Is(err, errMissingOAuthProvider) {
		return api.ErrorKindAuthFailure, true
	}
	// IMAP LOGIN/AUTHENTICATE itself was rejected (wrong password, or the
	// IMAP server rejected an otherwise-valid access token).
	return api.ErrorKindAuthFailure, false
}

// maxLoggedServerResponse caps the logged response so a hostile or broken
// server cannot flood the log through this field. Real tagged responses are
// far shorter than this.
const maxLoggedServerResponse = 200

// commandFailedServerResponse extracts the IMAP server's own tagged
// response from a failed command, for diagnosis. Originally written for
// authentication failures (Task #187, hence the examples below), reused
// as-is by isRateLimited's logging (Task #206) since the extraction logic
// doesn't care which command failed. Returns an empty string when the
// failure did not come from a tagged NO/BAD — an OAuth token exchange
// failure, say, has no IMAP response to report.
//
// Safe to log: a tagged response is the server talking, and IMAP servers do
// not echo the command that failed, so the LOGIN line's password cannot
// appear here. Sanitized and length-capped regardless.
func commandFailedServerResponse(err error) string {
	var commandFailed *imapclient.CommandFailedError
	if !errors.As(err, &commandFailed) {
		return ""
	}
	response := commandFailed.Response
	if len(response) > maxLoggedServerResponse {
		response = response[:maxLoggedServerResponse]
	}
	return push.SanitizeForLog(response)
}

// isRateLimited reports whether err is an IMAP tagged failure carrying a
// `[LIMIT]` response code (Task #206) — observed from Yahoo Japan
// (imap.mail.yahoo.co.jp) on STATUS: `A87 NO [LIMIT] STATUS Rate limit
// hit.` This is NOT a connection-level problem: the TCP/TLS connection and
// the IMAP session's authentication are both still perfectly good, only
// this one command was refused.
//
// Why this needs its own branch rather than falling through to the generic
// "connection error, reconnect" path: reconnecting means a fresh LOGIN, and
// repeated LOGINs are exactly what triggers Yahoo's *separate*
// authentication lockout (Task #187's defaultAuthFailureRetryInterval,
// whose real-world trigger doc comment describes the same account). Before
// this fix, production showed the resulting loop directly: rate limit on
// STATUS -> treated as a connection error -> reconnect -> LOGIN -> LOGIN
// rejected (the account was now locked) -> ~30+ minute lockout wait ->
// LOGIN eventually succeeds -> same command volume as before -> rate
// limited again. See connectAndWatch's isRateLimited branch and
// docs/architecture.md's "IDLE 非対応の IMAP サーバーには NOOP
// キープアライブが必須" pitfall entry (Task #206 addendum) for the full
// narrative and the production log excerpt this was diagnosed from.
func isRateLimited(err error) bool {
	var commandFailed *imapclient.CommandFailedError
	if !errors.As(err, &commandFailed) {
		return false
	}
	return strings.Contains(strings.ToUpper(commandFailed.Response), "[LIMIT]")
}

func minDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}
