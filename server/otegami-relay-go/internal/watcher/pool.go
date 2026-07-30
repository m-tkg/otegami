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
// credentials that are simply wrong).
const maxConsecutiveAuthFailures = 3

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
	if opts.ConnectTimeout == 0 {
		opts.ConnectTimeout = 15 * time.Second
	}
	if opts.OAuth == nil {
		opts.OAuth = oauth.Unconfigured{}
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

		err = p.connectAndWatch(ctx, client, record, &consecutiveAuthFailures, &backoff)
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
			"serverResponse", authFailureServerResponse(err),
		)
		// Task #175: an invalid_grant (dead refresh token) or a locally-
		// detected configuration problem stops the watch on the very
		// first occurrence — retrying either can never succeed. Every
		// other case (including a wrong password) retries up to
		// maxConsecutiveAuthFailures times.
		givingUp := stopsImmediately || *consecutiveAuthFailures >= maxConsecutiveAuthFailures
		// Task #173: persist this so GET /v1/watches can tell the app
		// which account's watch actually stopped.
		_ = p.store.RecordWatchError(ctx, record.ID, kind, givingUp)
		if givingUp {
			p.logger.Error("watch stopped after authentication failure",
				"watchId", record.ID, "kind", string(kind))
			return errWatchStopped
		}
		sleepCtx(ctx, *backoff)
		*backoff = minDuration(*backoff*2, 5*time.Minute)
		return nil
	}

	*consecutiveAuthFailures = 0
	*backoff = 2 * time.Second
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
			sleepCtx(ctx, p.opts.PollInterval)
			if ctx.Err() != nil {
				return ctx.Err()
			}
		}

		newUIDNext, err := client.StatusUIDNext(record.Mailbox)
		if err != nil {
			return err
		}
		if newUIDNext > baselineUIDNext {
			baselineUIDNext = newUIDNext
			p.fire(ctx, record, newUIDNext)
		}
	}
	return ctx.Err()
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

// authFailureServerResponse extracts the IMAP server's own tagged response
// from an authentication failure, for diagnosis (Task #187). Returns an
// empty string when the failure did not come from a tagged NO/BAD — an
// OAuth token exchange failure, say, has no IMAP response to report.
//
// Safe to log: a tagged response is the server talking, and IMAP servers do
// not echo the command that failed, so the LOGIN line's password cannot
// appear here. Sanitized and length-capped regardless.
func authFailureServerResponse(err error) string {
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

func minDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}
