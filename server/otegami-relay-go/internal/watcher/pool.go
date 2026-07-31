// Package watcher runs one IMAP connection per watch, IDLE-ing for new mail
// on IDLE-capable servers, or (Task #215) reconnecting every PollInterval
// for a short connect->SELECT->LOGOUT check on servers without IDLE — and
// firing a push through push.Sender when UIDNEXT advances. Loosely mirrors
// WatcherPool.swift (server/otegami-relay/Sources/OtegamiRelay/Watcher/
// WatcherPool.swift), though the non-IDLE poll design has since diverged
// from it — see runPollCycle's doc comment for why.
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
	// PollInterval (Task #215): for a server without IDLE, how long a
	// watch stays disconnected between short connect -> SELECT -> LOGOUT
	// cycles (default 20 minutes — see New()'s doc comment for why this
	// value, specifically). See runPollCycle's doc comment for why this
	// replaced the earlier "hold one connection open, NOOP to keep it
	// alive, STATUS every PollInterval" design (Task #201/#206) — that
	// design's own keepalive traffic was what tripped Yahoo Japan's
	// hourly rate limit in production.
	PollInterval time.Duration
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
	// IdleRateLimitKeepAliveInterval (Task #215): while an IDLE-capable
	// connection waits out a `[LIMIT]` rejection (RateLimitInitialWait/
	// RateLimitWaitCap above), how often a NOOP is sent to keep it from
	// going quiet long enough for the server to drop it — see
	// sleepWithKeepalive and connectAndWatch's isRateLimited branch.
	// Default 45s, reusing the interval Task #201 measured as safely
	// under Yahoo Japan's own no-traffic timeout (Yahoo doesn't support
	// IDLE, so this specific branch has no production evidence of ever
	// needing it, but the same principle applies regardless of which
	// server eventually does: a connection held open through a wait must
	// see traffic).
	IdleRateLimitKeepAliveInterval time.Duration
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
		// Task #215: 20 minutes — 3 reconnect cycles/hour, ~12
		// commands/hour (LOGIN+CAPABILITY+SELECT+LOGOUT per cycle). This
		// is more conservative than the 10-15 minute range the initial
		// analysis settled on (see runPollCycle's doc comment): while
		// this fix was in progress, the same production account's Yahoo
		// lockout escalated from "push notifications stop" to "the app's
		// own direct IMAP login stops working too" — the account-wide
		// lock isn't scoped to just this relay's connection. With no
		// published threshold to anchor against, and given that failure
		// mode is far worse than a slower notification, 20 minutes trades
		// away some of the original range's headroom for a bigger safety
		// margin: ~7.7x under the ~92 commands/hour that tripped the rate
		// limit, ~8x under the ~24 logins/hour that caused Task #187's
		// lockout. If production still shows trouble at this cadence, the
		// next step is disabling push for non-IDLE servers entirely
		// (foreground sync only) rather than tuning this further on
		// guesses — see docs/architecture.md pitfall "i." Task #215
		// addendum.
		opts.PollInterval = 20 * time.Minute
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
	if opts.IdleRateLimitKeepAliveInterval == 0 {
		opts.IdleRateLimitKeepAliveInterval = 45 * time.Second
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
	// Task #215: state for the non-IDLE poll design (runPollCycle) that
	// must survive across reconnects, unlike the idle path's
	// baselineUIDNext (which is fine living inside one connectAndWatch
	// call, since that call spans the whole connection's life there).
	// lastKnownUIDNext == 0 means "no poll cycle has completed yet" — a
	// real UIDNEXT is always >= 1 (RFC 3501), so 0 safely means "don't
	// fire on the very first cycle."
	lastKnownUIDNext := 0
	pollRateLimitWait := p.opts.RateLimitInitialWait

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

		err = p.connectAndWatch(ctx, client, record, &consecutiveAuthFailures, &backoff, &authBackoff, &lastKnownUIDNext, &pollRateLimitWait)
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
		case errors.Is(err, errPollCycleComplete):
			// Task #215: a non-IDLE watch's connect->check->LOGOUT cycle
			// finished with no error — this is the *expected* shape of a
			// poll cycle now (see runPollCycle), not a connection failure,
			// so it must not touch backoff/authBackoff or get recorded as
			// an error. Sleep the full interval, then reconnect fresh.
			sleepCtx(ctx, p.opts.PollInterval)
			continue
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
// SELECT baseline, then (Task #215) either IDLE-loop until an error or
// cancellation (IDLE-capable servers — iCloud/Gmail/Outlook, unaffected by
// this task), or run exactly one poll cycle and hand back control so the
// caller disconnects and waits out the next PollInterval (non-IDLE servers
// — Yahoo Japan is the only one seen in production; see runPollCycle).
// Returns:
//   - errWatchStopped: give up permanently (already persisted).
//   - nil: an auth failure was handled (recorded + backoff slept) and the
//     outer loop should retry immediately.
//   - errPollCycleComplete: a poll cycle (or an early rate-limit wait, see
//     handleEarlyRateLimit) finished with no error — the outer loop sleeps
//     PollInterval and reconnects, without touching backoff/authBackoff or
//     recording an error.
//   - any other error: a connection-level failure the outer loop records
//     and retries with backoff.
func (p *Pool) connectAndWatch(
	ctx context.Context,
	client *imapclient.Client,
	record *store.WatchRecord,
	consecutiveAuthFailures *int,
	backoff *time.Duration,
	authBackoff *time.Duration,
	lastKnownUIDNext *int,
	pollRateLimitWait *time.Duration,
) error {
	if err := client.Connect(record.ImapHost, record.ImapPort, record.ImapUseTLS, p.opts.ConnectTimeout, p.opts.NetworkPolicy); err != nil {
		return err
	}

	if err := p.authenticate(ctx, client, record); err != nil {
		_ = client.Close()
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if isRateLimited(err) {
			// Task #215: a `[LIMIT]` rejection of LOGIN itself says
			// nothing about credential validity — classifyAuthFailure
			// below has no way to tell this apart from a wrong password,
			// and treating it as one would trigger Task #187's long
			// authBackoff (30+ minutes in production) for what's actually
			// a short-lived rate limit. Handle it exactly like a
			// post-LOGIN rate limit instead (handleEarlyRateLimit): wait,
			// retry immediately, no auth-failure bookkeeping touched. No
			// production evidence of Yahoo rate-limiting LOGIN itself
			// specifically (only STATUS — Task #206), but nothing rules
			// it out either, and this fixture-driven test suite found the
			// gap (TestPollDesignBacksOffWithoutRepeatedLoginsWhenRateLimited)
			// under a tight enough window budget that LOGIN itself gets
			// rejected on a retried connection.
			return p.handleEarlyRateLimit(ctx, record, err, pollRateLimitWait, "LOGIN")
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
	*pollRateLimitWait = p.opts.RateLimitInitialWait
	_ = p.store.MarkWatchConnected(ctx, record.ID)

	selectResult, err := client.Select(record.Mailbox)
	if err != nil {
		return p.handleEarlyRateLimit(ctx, record, err, pollRateLimitWait, "SELECT")
	}
	baselineUIDNext := 0
	if selectResult.UidNext != nil {
		baselineUIDNext = *selectResult.UidNext
	} else {
		// Rare fallback for a server whose SELECT response omits UIDNEXT.
		// Task #215: this used to swallow statusErr entirely, silently
		// leaving baselineUIDNext at its zero value — harmless for the old
		// idle-only design (worst case, one spurious push on the first
		// IDLE wake) but actively wrong for the new poll design, where
		// this same value is compared against the *previous* cycle's
		// UIDNEXT (see runPollCycle) — a silently-swallowed 0 here would
		// look like the mailbox shrank, then make the next cycle's real
		// value look like a huge (false) jump. Propagate it instead.
		fromStatus, statusErr := client.StatusUIDNext(record.Mailbox)
		if statusErr != nil {
			return p.handleEarlyRateLimit(ctx, record, statusErr, pollRateLimitWait, "STATUS")
		}
		baselineUIDNext = fromStatus
	}
	idleSupported, err := client.CapabilitiesIncludeIdle()
	if err != nil {
		idleSupported = false
	}

	p.logger.Info("watch connected",
		"watchId", record.ID, "idle", idleSupported, "uidNext", baselineUIDNext)

	if !idleSupported {
		// Task #215: a non-IDLE watch only ever runs one poll cycle per
		// connection — see runPollCycle's doc comment for why.
		return p.runPollCycle(ctx, record, baselineUIDNext, lastKnownUIDNext, pollRateLimitWait, client)
	}

	// Task #206: how long to wait, on this same connection, the next time
	// STATUS comes back `[LIMIT]` — see isRateLimited's doc comment. Reset
	// to the initial value after every STATUS that doesn't hit the limit,
	// so one isolated blip doesn't permanently slow this watch down.
	rateLimitWait := p.opts.RateLimitInitialWait

	for ctx.Err() == nil {
		gotExists, err := client.Idle(record.Mailbox, p.opts.IdleMaxWait)
		if err != nil {
			return err
		}
		if !gotExists {
			continue
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
				// Task #215 "problem 1" fix: the original version of this
				// wait was a bare sleepCtx with no traffic on the
				// connection at all — exactly the pattern that, on a
				// non-IDLE server with a short inactivity timeout (Yahoo
				// Japan), killed the connection mid-wait and got
				// misclassified as a plain connection error, forcing an
				// immediate reconnect (a fresh LOGIN) right back into the
				// lockout this fix exists to avoid. This branch is only
				// reached by an IDLE-capable server (no non-IDLE watch
				// gets this far — see the runPollCycle branch above), so
				// there's no production evidence of it actually dying
				// mid-wait, but the same principle applies regardless of
				// which server eventually hits it: a wait on a held-open
				// connection must keep it alive, not go silent.
				if err := sleepWithKeepalive(ctx, client, rateLimitWait, p.opts.IdleRateLimitKeepAliveInterval); err != nil {
					return err
				}
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

// runPollCycle (Task #215) is the entire lifetime of a non-IDLE watch's
// connection: the caller (connectAndWatch) has already connected,
// authenticated, and observed the mailbox's current UIDNEXT via SELECT
// (uidNext) — this fires a push if it advanced since the previous cycle
// (lastKnownUIDNext, which — unlike a plain local variable — survives
// across reconnects at the runWatchLoop level), sends LOGOUT, and returns
// errPollCycleComplete so runWatchLoop closes the connection and sleeps a
// full PollInterval before the next one.
//
// Why disconnect between checks instead of holding one connection open
// (see docs/architecture.md pitfall "i." Task #215 addendum for the full
// narrative and production log excerpts): the Task #201/#206 design this
// replaces needed ~92 IMAP commands/hour per watch to stay both connected
// (a NOOP every 45s — Yahoo Japan's real inactivity timeout is under 2
// minutes, measured in Task #201) and current (a STATUS every 5 minutes).
// Production logs showed Yahoo answering STATUS with `[LIMIT]` at almost
// exactly one hour after each LOGIN, twice, at exactly that command
// volume — strong evidence of an hourly budget in that neighborhood. The
// two goals were in tension on this specific server: the traffic needed to
// keep the connection alive is itself what tripped the rate limit, so no
// amount of retuning the keepalive/poll intervals within that design can
// satisfy both at once (see Options.PollInterval's doc comment for why
// the sibling idea — a much longer keepalive interval alone — was
// rejected too: it can't outlast the sub-2-minute inactivity timeout).
//
// Reconnecting every PollInterval sidesteps the tension instead of trying
// to win it: nothing sits idle, so nothing needs a keepalive, and the
// total cost per cycle is just LOGIN+CAPABILITY+SELECT+LOGOUT (4 commands,
// every cycle — CAPABILITY is re-checked each time rather than cached, in
// case a server's advertised capabilities ever change) — 3 connects/hour
// and ~12 commands/hour at the default 20-minute interval, far under both
// the ~92/hour budget that tripped the rate limit and the ~24 logins/hour
// (576/day) that caused Task #187's separate auth lockout. See New()'s
// doc comment for why the interval landed at 20 minutes specifically
// (more conservative than this design's initial 10-15 minute analysis) —
// production showed the same account's Yahoo lockout escalating to
// blocking the app's own direct IMAP login, not just this relay's
// connection, while this fix was still in progress. The cost is
// notifications lagging up to one PollInterval (default 20 minutes)
// behind actual delivery — see docs/architecture.md pitfall "i." Task
// #215 addendum for the trade-off this was weighed against, including
// the fallback considered if even this cadence turns out unsafe
// (disabling push for non-IDLE servers entirely).
func (p *Pool) runPollCycle(
	ctx context.Context,
	record *store.WatchRecord,
	uidNext int,
	lastKnownUIDNext *int,
	pollRateLimitWait *time.Duration,
	client *imapclient.Client,
) error {
	if *lastKnownUIDNext != 0 && uidNext > *lastKnownUIDNext {
		p.fire(ctx, record, uidNext)
	}
	*lastKnownUIDNext = uidNext
	*pollRateLimitWait = p.opts.RateLimitInitialWait
	// Best-effort: the connection is being torn down by the caller
	// regardless (runWatchLoop's client.Close() right after
	// connectAndWatch returns), so a LOGOUT failure here changes nothing.
	_ = client.Logout()
	return errPollCycleComplete
}

// handleEarlyRateLimit (Task #215) checks whether err is a `[LIMIT]`
// rejection of the SELECT (or its STATUS fallback) that runs immediately
// after LOGIN, before connectAndWatch has even decided whether this watch
// is IDLE-capable. Falling through to the generic connection-error path
// here would have the outer loop reconnect — a fresh LOGIN — within a few
// seconds (the connection-error backoff starts at 2s), risking exactly the
// relogin storm Task #215 exists to avoid, for what would otherwise look
// like an ordinary transient error. Any other error is returned unchanged.
//
// This connection is brand new (LOGIN just succeeded), so there is nothing
// worth keeping alive here the way the IDLE path's rate-limit wait does —
// simplest and safe is to close it and wait out rateLimitWait right here,
// then return nil so the outer loop (runWatchLoop) retries immediately —
// the wait already happened, so it must NOT also sleep PollInterval on top
// (that was a real bug caught by this task's own
// TestPollDesignBacksOffWithoutRepeatedLoginsWhenRateLimited: returning
// errPollCycleComplete here made runWatchLoop add a second, much longer
// sleep after this function's own, silently turning "back off
// rateLimitWait" into "back off rateLimitWait + PollInterval").
func (p *Pool) handleEarlyRateLimit(ctx context.Context, record *store.WatchRecord, err error, rateLimitWait *time.Duration, command string) error {
	if !isRateLimited(err) {
		return err
	}
	p.logger.Warn("watch rate limited by server right after connecting, backing off before retrying",
		"watchId", record.ID, "command", command, "wait", rateLimitWait.String(),
		"serverResponse", commandFailedServerResponse(err))
	_ = p.store.RecordWatchError(ctx, record.ID, api.ErrorKindConnectionError, false)
	sleepCtx(ctx, *rateLimitWait)
	*rateLimitWait = minDuration(*rateLimitWait*2, p.opts.RateLimitWaitCap)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return nil
}

// errPollCycleComplete (Task #215) signals runWatchLoop that a non-IDLE
// watch's connect->check->LOGOUT cycle (runPollCycle) — or an early
// rate-limit wait before that point (handleEarlyRateLimit) — finished with
// no error. The outer loop sleeps PollInterval and reconnects, without
// touching backoff/authBackoff or recording an error, since this is the
// expected shape of a poll cycle, not a failure.
var errPollCycleComplete = errors.New("poll cycle complete")

// sleepWithKeepalive sleeps for d, sending a NOOP over client every step so
// a connection held open through a long wait keeps seeing traffic instead
// of going quiet for the whole duration (Task #215's "problem 1" fix for
// connectAndWatch's IDLE-path isRateLimited branch — see that branch's
// comment). Returns nil on ctx cancellation (the caller checks ctx.Err()
// itself), or the NOOP's error if the connection dies anyway despite the
// keepalive — the caller treats that exactly like any other connection
// error.
func sleepWithKeepalive(ctx context.Context, client *imapclient.Client, d, step time.Duration) error {
	remaining := d
	for remaining > 0 {
		s := step
		if s > remaining {
			s = remaining
		}
		sleepCtx(ctx, s)
		if ctx.Err() != nil {
			return nil
		}
		remaining -= s
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

// fire mirrors WatcherPool.fire(record:uidNext:). Task #208: a `watch` row
// no longer maps to a single device — every device subscribed to it (one
// `watch_subscription` row each, sharing this one IMAP connection) gets its
// own push, each carrying that device's own locally-meaningful accountId.
// One subscriber with no push token yet, or a failed send, does not stop
// the others from being notified.
func (p *Pool) fire(ctx context.Context, record *store.WatchRecord, uidNext int) {
	subscribers, err := p.store.WatchSubscribers(ctx, record.ID)
	if err != nil {
		p.logger.Warn("could not list watch subscribers", "watchId", record.ID, "error", err.Error())
		return
	}
	for _, sub := range subscribers {
		target, err := p.store.PushTarget(ctx, sub.DeviceID)
		if err != nil || target == nil {
			p.logger.Debug("watch fired but device has no push token yet", "watchId", record.ID)
			continue
		}
		err = p.sender.Send(ctx, target.ApnsToken, target.Environment, api.PushNotificationPayload{
			AccountID: sub.AccountID,
			UidNext:   uidNext,
		})
		if err != nil {
			p.logger.Warn("push send failed",
				"watchId", record.ID, "error", push.SanitizeForLog(err.Error()))
		}
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
// limited again. See connectAndWatch's isRateLimited branch (still used by
// the IDLE-capable path only, Task #215) and docs/architecture.md's "IDLE
// 非対応の IMAP サーバーには NOOP キープアライブが必須" pitfall entry
// (Task #206/#215 addenda) for the full narrative and the production log
// excerpts this was diagnosed from — including why the Task #206/#201
// keepalive-and-wait design this docstring describes was later replaced,
// for non-IDLE servers, by runPollCycle's disconnect-between-checks design.
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
