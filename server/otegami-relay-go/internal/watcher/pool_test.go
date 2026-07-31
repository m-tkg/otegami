package watcher

import (
	"context"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/m-tkg/otegami-relay-go/internal/api"
	"github.com/m-tkg/otegami-relay-go/internal/cryptox"
	"github.com/m-tkg/otegami-relay-go/internal/imaptest"
	"github.com/m-tkg/otegami-relay-go/internal/oauth"
	"github.com/m-tkg/otegami-relay-go/internal/security"
	"github.com/m-tkg/otegami-relay-go/internal/store"
)

// fakePushSender mirrors FakePushSender — records every call instead of
// sending anything.
type pushCall struct {
	DeviceToken string
	Environment api.Environment
	Payload     api.PushNotificationPayload
}

type fakePushSender struct {
	mu    sync.Mutex
	calls []pushCall
}

func (f *fakePushSender) Send(_ context.Context, deviceToken string, environment api.Environment, payload api.PushNotificationPayload) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, pushCall{DeviceToken: deviceToken, Environment: environment, Payload: payload})
	return nil
}

func (f *fakePushSender) Calls() []pushCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]pushCall(nil), f.calls...)
}

// fakeExchanger mirrors FakeOAuthTokenExchanger — either always succeeds
// with a fixed access token, or always fails with a fixed error.
type exchangeCall struct {
	Provider     api.WatchAuthProvider
	RefreshToken string
}

type fakeExchanger struct {
	mu          sync.Mutex
	calls       []exchangeCall
	accessToken string
	err         error
}

func (f *fakeExchanger) AccessToken(_ context.Context, provider api.WatchAuthProvider, refreshToken string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, exchangeCall{Provider: provider, RefreshToken: refreshToken})
	if f.err != nil {
		return "", f.err
	}
	return f.accessToken, nil
}

func (f *fakeExchanger) Calls() []exchangeCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]exchangeCall(nil), f.calls...)
}

func newTestStore(t *testing.T) *store.Store {
	t.Helper()
	c, err := cryptox.New(make([]byte, 32))
	if err != nil {
		t.Fatal(err)
	}
	s, err := store.Open(":memory:", c)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func testLogger() *slog.Logger {
	return slog.New(slog.DiscardHandler)
}

func newTestPool(t *testing.T, s *store.Store, sender *fakePushSender, exchanger oauth.TokenExchanger) *Pool {
	t.Helper()
	pool := New(s, sender, testLogger(), Options{
		IdleMaxWait:  3 * time.Second,
		PollInterval: 200 * time.Millisecond,
		// The fake server binds loopback on an OS-assigned ephemeral port
		// — legitimate for an in-process test, not the SSRF threat
		// security.Strict() defends against.
		NetworkPolicy: security.PermissiveForTesting(),
		OAuth:         exchanger,
	})
	t.Cleanup(pool.Stop)
	return pool
}

func createWatch(t *testing.T, s *store.Store, port int, accountID string, auth api.WatchAuth, apnsEnv api.Environment, apnsToken string) (deviceID, watchID string) {
	t.Helper()
	ctx := t.Context()
	device, err := s.CreateDevice(ctx, apnsToken, apnsEnv)
	if err != nil {
		t.Fatal(err)
	}
	watch, err := s.CreateWatch(ctx, device.DeviceID, api.CreateWatchRequest{
		AccountID:    accountID,
		ImapHost:     "127.0.0.1",
		ImapPort:     port,
		ImapUseTLS:   false,
		ImapUsername: "user@example.com",
		Auth:         auth,
		Mailbox:      "INBOX",
	})
	if err != nil {
		t.Fatal(err)
	}
	return device.DeviceID, watch.WatchID
}

func waitForCalls(t *testing.T, sender *fakePushSender, atLeast int, timeout time.Duration) []pushCall {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		calls := sender.Calls()
		if len(calls) >= atLeast {
			return calls
		}
		time.Sleep(50 * time.Millisecond)
	}
	return sender.Calls()
}

func TestIdleFlowFiresPush(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SetInitialState(5, 6)
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := newTestPool(t, s, sender, nil)
	_, watchID := createWatch(t, s, port, "account-1",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"},
		api.EnvironmentSandbox, "device-token-abc")
	pool.AddWatch(watchID)

	// Give the watch loop time to connect, LOGIN, SELECT, and enter IDLE.
	time.Sleep(300 * time.Millisecond)
	server.DeliverNewMail()

	calls := waitForCalls(t, sender, 1, 5*time.Second)
	if len(calls) != 1 {
		t.Fatalf("got %d calls: %+v", len(calls), calls)
	}
	if calls[0].DeviceToken != "device-token-abc" || calls[0].Environment != api.EnvironmentSandbox {
		t.Fatalf("got %+v", calls[0])
	}
	if calls[0].Payload.AccountID != "account-1" || calls[0].Payload.UidNext != 7 {
		t.Fatalf("got %+v", calls[0].Payload)
	}
}

func TestPollingFlowFiresPush(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SupportsIdle = false
	server.SetInitialState(2, 3)
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := newTestPool(t, s, sender, nil)
	_, watchID := createWatch(t, s, port, "account-2",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"},
		api.EnvironmentProduction, "poll-device-token")
	pool.AddWatch(watchID)

	// Let the loop establish its UIDNEXT baseline via SELECT first.
	time.Sleep(300 * time.Millisecond)
	server.DeliverNewMail()

	calls := waitForCalls(t, sender, 1, 5*time.Second)
	if len(calls) != 1 {
		t.Fatalf("got %d calls", len(calls))
	}
	if calls[0].Payload.AccountID != "account-2" || calls[0].Payload.UidNext != 4 {
		t.Fatalf("got %+v", calls[0].Payload)
	}
	if calls[0].Environment != api.EnvironmentProduction {
		t.Fatalf("got %+v", calls[0])
	}
}

// TestPollDesignReconnectsEachCycleAndSurvivesAggressiveInactivityTimeout
// is Task #215's regression test for the redesigned non-IDLE poll path,
// replacing the pre-#215 TestPollingKeepAliveSurvivesServerInactivityTimeout
// (which asserted the *opposite* property: exactly one LOGIN, kept alive
// via NOOP). That design — one held-open connection, NOOP every 45s to
// survive Yahoo Japan's sub-2-minute inactivity timeout, STATUS every
// PollInterval — is what production showed hitting a `[LIMIT]` rate limit
// at almost exactly one hour after every LOGIN (docs/architecture.md
// pitfall "i." Task #215 addendum): the very traffic needed to survive the
// inactivity timeout is what tripped the rate limit. Task #215 replaces it
// with a short connect->SELECT->LOGOUT cycle every PollInterval and no
// held-open connection at all — so an aggressive InactivityTimeout no
// longer matters (nothing is ever left idle on the wire), and each
// disconnect between cycles is expected, not an error.
func TestPollDesignReconnectsEachCycleAndSurvivesAggressiveInactivityTimeout(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SupportsIdle = false
	server.SetInitialState(2, 3)
	// Shorter than a single command round-trip would ever plausibly need
	// to survive between cycles — proves this constraint simply no longer
	// applies to the new design (the old design required NOOPs comfortably
	// under this exact kind of value to survive; the new one doesn't
	// interact with it at all).
	server.InactivityTimeout = 50 * time.Millisecond
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := New(s, sender, testLogger(), Options{
		PollInterval:  150 * time.Millisecond,
		NetworkPolicy: security.PermissiveForTesting(),
	})
	t.Cleanup(pool.Stop)
	deviceID, watchID := createWatch(t, s, port, "account-poll-reconnect",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"},
		api.EnvironmentSandbox, "poll-reconnect-device-token")
	pool.AddWatch(watchID)

	// Let several PollInterval cycles elapse. Poll throughout (rather than
	// a single sleep-then-check) so a transient "stopped" status — which
	// would mean a disconnect got misclassified as fatal — can't hide
	// behind the next successful reconnect's MarkWatchConnected clearing
	// it back to active.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		summaries, err := s.ListWatchSummaries(t.Context(), deviceID)
		if err != nil {
			t.Fatal(err)
		}
		if len(summaries) != 1 {
			t.Fatalf("got %d summaries", len(summaries))
		}
		if summaries[0].Status == api.WatchStatusStopped {
			t.Fatalf("watch stopped — a disconnect between poll cycles must never be treated as fatal: %+v", summaries[0])
		}
		if server.LoginCount() >= 3 {
			break
		}
		time.Sleep(30 * time.Millisecond)
	}
	if got := server.LoginCount(); got < 3 {
		t.Fatalf("expected multiple reconnects (one LOGIN per poll cycle), got %d", got)
	}

	// New mail delivered between cycles (no client connected at the
	// moment it's delivered) must still be picked up by the next cycle's
	// SELECT.
	server.DeliverNewMail()
	calls := waitForCalls(t, sender, 1, 5*time.Second)
	if len(calls) != 1 {
		t.Fatalf("got %d calls: %+v", len(calls), calls)
	}
	if calls[0].Payload.AccountID != "account-poll-reconnect" || calls[0].Payload.UidNext != 4 {
		t.Fatalf("got %+v", calls[0].Payload)
	}
}

// TestPollDesignStaysUnderHourlyRateLimitBudget is Task #215's core design
// validation: run the poll design against a fake server that enforces a
// time-windowed command budget (RateLimitWindow/RateLimitWindowBudget —
// modeling the production evidence of an hourly budget, not a
// per-connection count) sized so that the *pre-#215* design's ~92
// commands/hour would have blown it, but the new design's ~4-6
// connects/hour (LOGIN+CAPABILITY+SELECT+LOGOUT per cycle) comfortably
// doesn't. Zero rejections over several simulated windows is the proof.
func TestPollDesignStaysUnderHourlyRateLimitBudget(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SupportsIdle = false
	server.SetInitialState(2, 3)
	// One simulated "hour" = 1 second. A budget of 40 in that window is
	// well below what the old design's cadence would have used (scaled
	// proportionally, ~92) but several times what the new design actually
	// needs per window at the PollInterval below (4 commands/cycle *
	// ~3-4 cycles/window ≈ 12-16) — deliberately not razor-thin, since
	// the point is demonstrating headroom, not tuning to the wire.
	server.RateLimitWindow = 1 * time.Second
	server.RateLimitWindowBudget = 40
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := New(s, sender, testLogger(), Options{
		PollInterval:  250 * time.Millisecond,
		NetworkPolicy: security.PermissiveForTesting(),
	})
	t.Cleanup(pool.Stop)
	_, watchID := createWatch(t, s, port, "account-budget",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"},
		api.EnvironmentSandbox, "budget-device-token")
	pool.AddWatch(watchID)

	// Several simulated hours' worth of cycles.
	time.Sleep(3500 * time.Millisecond)

	if got := server.RejectedCount(); got != 0 {
		t.Fatalf("expected the poll design to stay under the simulated hourly budget, got %d rejected commands", got)
	}
	if got := server.LoginCount(); got < 3 {
		t.Fatalf("expected several reconnect cycles to have happened, got %d LOGINs", got)
	}

	// Mail delivered partway through must still be detected.
	server.DeliverNewMail()
	calls := waitForCalls(t, sender, 1, 5*time.Second)
	if len(calls) != 1 {
		t.Fatalf("got %d calls: %+v", len(calls), calls)
	}
	if calls[0].Payload.AccountID != "account-budget" || calls[0].Payload.UidNext != 4 {
		t.Fatalf("got %+v", calls[0].Payload)
	}
	if got := server.RejectedCount(); got != 0 {
		t.Fatalf("expected still zero rejected commands after mail delivery, got %d", got)
	}
}

// TestPollDesignSurvivesRateLimitAndInactivityTimeoutTogether combines both
// of Task #215's fake-server scenarios at once — a windowed rate limit AND
// an aggressive inactivity timeout on the same server — mirroring the
// actual production server (Yahoo Japan has both constraints
// simultaneously). The poll design must keep working under both at once,
// not just each individually.
func TestPollDesignSurvivesRateLimitAndInactivityTimeoutTogether(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SupportsIdle = false
	server.SetInitialState(2, 3)
	server.InactivityTimeout = 50 * time.Millisecond
	server.RateLimitWindow = 1 * time.Second
	server.RateLimitWindowBudget = 40
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := New(s, sender, testLogger(), Options{
		PollInterval:  250 * time.Millisecond,
		NetworkPolicy: security.PermissiveForTesting(),
	})
	t.Cleanup(pool.Stop)
	deviceID, watchID := createWatch(t, s, port, "account-combined",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"},
		api.EnvironmentSandbox, "combined-device-token")
	pool.AddWatch(watchID)

	deadline := time.Now().Add(3500 * time.Millisecond)
	for time.Now().Before(deadline) {
		summaries, err := s.ListWatchSummaries(t.Context(), deviceID)
		if err != nil {
			t.Fatal(err)
		}
		if len(summaries) == 1 && summaries[0].Status == api.WatchStatusStopped {
			t.Fatalf("watch stopped under combined rate-limit + inactivity-timeout constraints: %+v", summaries[0])
		}
		time.Sleep(50 * time.Millisecond)
	}

	if got := server.RejectedCount(); got != 0 {
		t.Fatalf("expected zero rejected commands under the simulated hourly budget, got %d", got)
	}

	server.DeliverNewMail()
	calls := waitForCalls(t, sender, 1, 5*time.Second)
	if len(calls) != 1 {
		t.Fatalf("got %d calls: %+v", len(calls), calls)
	}
	if calls[0].Payload.AccountID != "account-combined" || calls[0].Payload.UidNext != 4 {
		t.Fatalf("got %+v", calls[0].Payload)
	}
}

// TestPollDesignBacksOffWithoutRepeatedLoginsWhenRateLimited deliberately
// sets a tight-enough window budget that the poll design *does* hit
// `[LIMIT]` (handleEarlyRateLimit, on the SELECT/STATUS right after LOGIN)
// and proves the recovery is a wait-and-retry, never a rapid relogin
// spiral — the exact pattern that turned Task #206's rate limit into
// Task #187's hours-long auth lockout in production. Consecutive LOGIN
// attempts after a rejection must be spaced at least RateLimitInitialWait
// apart, and the watch must never stop.
func TestPollDesignBacksOffWithoutRepeatedLoginsWhenRateLimited(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SupportsIdle = false
	server.SetInitialState(2, 3)
	// A budget tight enough that LOGIN succeeds but the CAPABILITY/SELECT
	// immediately after it does not — every cycle gets rate limited.
	server.RateLimitWindow = 10 * time.Second
	server.RateLimitWindowBudget = 1
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := New(s, sender, testLogger(), Options{
		// PollInterval deliberately irrelevant here — every cycle is
		// rejected before it ever reaches errPollCycleComplete's normal
		// PollInterval sleep; RateLimitInitialWait governs the pacing.
		PollInterval:         5 * time.Second,
		NetworkPolicy:        security.PermissiveForTesting(),
		RateLimitInitialWait: 300 * time.Millisecond,
		RateLimitWaitCap:     1 * time.Second,
	})
	t.Cleanup(pool.Stop)
	deviceID, watchID := createWatch(t, s, port, "account-spiral-guard",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"},
		api.EnvironmentSandbox, "spiral-guard-device-token")
	pool.AddWatch(watchID)

	deadline := time.Now().Add(2500 * time.Millisecond)
	for time.Now().Before(deadline) {
		summaries, err := s.ListWatchSummaries(t.Context(), deviceID)
		if err != nil {
			t.Fatal(err)
		}
		if len(summaries) == 1 && summaries[0].Status == api.WatchStatusStopped {
			t.Fatalf("watch stopped while merely rate limited: %+v", summaries[0])
		}
		time.Sleep(50 * time.Millisecond)
	}

	attempts := server.LoginAttempts()
	if len(attempts) < 2 {
		t.Fatalf("expected at least 2 LOGIN attempts to compare spacing, got %d", len(attempts))
	}
	for i := 1; i < len(attempts); i++ {
		gap := attempts[i].Sub(attempts[i-1])
		// A little slack below the configured wait for scheduling jitter,
		// but nowhere near the old 2-second connection-error backoff's
		// starting point, let alone an immediate retry.
		if gap < 250*time.Millisecond {
			t.Fatalf("LOGIN attempts %d and %d only %s apart — rate limit recovery must back off, not spiral (attempts: %v)",
				i-1, i, gap, attempts)
		}
	}
}

// TestIdleRateLimitWaitKeepsConnectionAliveViaNoop is Task #206's original
// regression test, adapted for Task #215: the STATUS-after-IDLE-wake
// `[LIMIT]` wait (connectAndWatch's isRateLimited branch, still used by the
// IDLE-capable path — Yahoo Japan doesn't support IDLE, so it never took
// this exact branch, but non-IDLE watches don't hold a connection open
// through a wait at all anymore, see runPollCycle) must be waited out on
// the very same connection rather than reconnecting (a fresh LOGIN would
// risk the same relogin-storm lockout Task #187 diagnosed), AND — Task
// #215's "problem 1" fix — must keep that connection alive with NOOP
// keepalives while waiting, proven here by an aggressive InactivityTimeout
// the wait must survive. Before this fix, the wait was a bare sleep with
// no traffic at all, which is exactly the pattern that killed the
// connection mid-wait on Yahoo Japan's non-IDLE path in production.
//
// StatusUIDNext on the IDLE path is only ever called in response to an
// IDLE wake (an EXISTS arriving), not on a timer — so the retry after a
// rate-limited wait needs its own fresh wake, which this test supplies as
// a second DeliverNewMail after the wait has had time to resolve. LoginCount
// staying at 1 throughout is the proof no reconnect happened; the eventual
// push after RateLimitStatusCount is exhausted proves the watch actually
// resumed rather than getting stuck.
func TestIdleRateLimitWaitKeepsConnectionAliveViaNoop(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SetInitialState(2, 3) // SupportsIdle defaults to true.
	// A real IDLE session sends nothing at all from the client side while
	// legitimately waiting for mail (RFC 2177 — that's the whole point of
	// IDLE), so InactivityTimeout must comfortably outlast every ordinary
	// silent IDLE gap in this test (connect/setup, and the second wake
	// below); it's only the rate-limit *wait* — a distinct, non-IDLE phase
	// free to send NOOP — that this value is deliberately shorter than, so
	// the keepalive is what has to carry it.
	server.InactivityTimeout = 500 * time.Millisecond
	// The first STATUS call (after the IDLE wake below) hits the limit;
	// the next one (after the second wake below) succeeds normally.
	server.RateLimitStatusCount = 1
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := New(s, sender, testLogger(), Options{
		IdleMaxWait:   5 * time.Second,
		PollInterval:  150 * time.Millisecond,
		NetworkPolicy: security.PermissiveForTesting(),
		// Deliberately longer than InactivityTimeout above: without the
		// keepalive fix, sitting silent for this whole wait would get the
		// connection dropped well before it finishes.
		RateLimitInitialWait: 1200 * time.Millisecond,
		RateLimitWaitCap:     2 * time.Second,
		// Comfortably under InactivityTimeout, and short enough relative
		// to RateLimitInitialWait that several steps happen during the
		// wait — proving the keepalive loop, not a lucky single NOOP, is
		// what keeps the connection alive.
		IdleRateLimitKeepAliveInterval: 100 * time.Millisecond,
	})
	t.Cleanup(pool.Stop)

	deviceID, watchID := createWatch(t, s, port, "account-rate-limited",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"},
		api.EnvironmentSandbox, "rate-limited-device-token")
	pool.AddWatch(watchID)

	// Give the watch time to connect and enter IDLE, then wake it with new
	// mail — the wake is what makes it call StatusUIDNext, which is where
	// RateLimitStatusCount bites.
	time.Sleep(150 * time.Millisecond)
	server.DeliverNewMail() // exists=3, uidNext=4 — this STATUS gets rejected.

	// Let the rate-limited STATUS attempt happen and resolve — proves the
	// watch is still alive and making progress (not stuck retrying
	// forever, not reconnecting, and — the InactivityTimeout above — not
	// losing the connection to inactivity mid-wait).
	deadline := time.Now().Add(5 * time.Second)
	sawRateLimitError := false
	for time.Now().Before(deadline) {
		summaries, err := s.ListWatchSummaries(t.Context(), deviceID)
		if err != nil {
			t.Fatal(err)
		}
		if len(summaries) != 1 {
			t.Fatalf("got %d summaries", len(summaries))
		}
		if summaries[0].Status == api.WatchStatusStopped {
			t.Fatalf("watch stopped, should have kept retrying on the same connection: %+v", summaries[0])
		}
		if summaries[0].LastErrorKind != nil && *summaries[0].LastErrorKind == api.ErrorKindConnectionError {
			sawRateLimitError = true
		}
		if server.LoginCount() > 1 {
			t.Fatalf("expected exactly 1 LOGIN (rate limit handled without reconnecting), got %d", server.LoginCount())
		}
		if sawRateLimitError {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !sawRateLimitError {
		t.Fatal("watch never recorded the rate-limit error")
	}

	// Give the rate-limit wait (started the moment sawRateLimitError went
	// true, above) comfortably long enough to finish — RateLimitInitialWait
	// plus a buffer — and the loop to be back inside a fresh Idle() call,
	// then wake it again: this StatusUIDNext call succeeds
	// (RateLimitStatusCount is exhausted), proving the watch actually
	// resumed rather than getting stuck waiting for an EXISTS that already
	// came and went.
	time.Sleep(1500 * time.Millisecond)
	server.DeliverNewMail() // exists=4, uidNext=5.

	calls := waitForCalls(t, sender, 1, 5*time.Second)
	if len(calls) != 1 {
		t.Fatalf("got %d calls: %+v", len(calls), calls)
	}
	if calls[0].Payload.AccountID != "account-rate-limited" || calls[0].Payload.UidNext != 5 {
		t.Fatalf("got %+v", calls[0].Payload)
	}
	if got := server.LoginCount(); got != 1 {
		t.Fatalf("expected still exactly 1 LOGIN after mail delivery, got %d", got)
	}

	summaries, err := s.ListWatchSummaries(t.Context(), deviceID)
	if err != nil {
		t.Fatal(err)
	}
	if len(summaries) != 1 || summaries[0].Status != api.WatchStatusActive {
		t.Fatalf("got %+v", summaries)
	}
}

func TestIdleTimeoutThenLaterMailStillFiresPush(t *testing.T) {
	// Parity with the Swift regression test: a legitimate IDLE timeout
	// (no mail within the window) must not break the connection — mail
	// delivered afterwards is still detected.
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SetInitialState(5, 6)
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := New(s, sender, testLogger(), Options{
		IdleMaxWait:   1 * time.Second, // let the first IDLE cycle time out
		PollInterval:  200 * time.Millisecond,
		NetworkPolicy: security.PermissiveForTesting(),
	})
	t.Cleanup(pool.Stop)
	_, watchID := createWatch(t, s, port, "account-timeout",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"},
		api.EnvironmentSandbox, "timeout-device-token")
	pool.AddWatch(watchID)

	// Let at least one full IDLE cycle time out with no mail at all.
	time.Sleep(2500 * time.Millisecond)
	if calls := sender.Calls(); len(calls) != 0 {
		t.Fatalf("no mail was delivered yet, got %+v", calls)
	}

	server.DeliverNewMail()
	calls := waitForCalls(t, sender, 1, 10*time.Second)
	if len(calls) != 1 {
		t.Fatalf("got %d calls", len(calls))
	}
	if calls[0].Payload.AccountID != "account-timeout" || calls[0].Payload.UidNext != 7 {
		t.Fatalf("got %+v", calls[0].Payload)
	}
}

func TestRepeatedLoginFailuresStopTheWatchAndPersistStatus(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.RejectsLogin = true
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := newTestPool(t, s, sender, nil)
	deviceID, watchID := createWatch(t, s, port, "account-auth-fail",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "wrong-password"},
		api.EnvironmentSandbox, "tok")
	pool.AddWatch(watchID)

	// maxConsecutiveAuthFailures (3) with the loop's own 2s/4s backoff
	// between attempts — poll rather than one fixed sleep.
	var summary *api.WatchSummary
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		summaries, err := s.ListWatchSummaries(t.Context(), deviceID)
		if err != nil {
			t.Fatal(err)
		}
		if len(summaries) == 1 && summaries[0].Status == api.WatchStatusStopped {
			summary = &summaries[0]
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if summary == nil {
		t.Fatal("watch never reached stopped status")
	}
	if summary.LastErrorKind == nil || *summary.LastErrorKind != api.ErrorKindAuthFailure {
		t.Fatalf("got %+v", summary)
	}
	if summary.LastErrorAt == nil {
		t.Fatal("lastErrorAt should be set")
	}
	if summary.LastConnectedAt != nil {
		t.Fatal("login never succeeded, lastConnectedAt should never get set")
	}
	if calls := sender.Calls(); len(calls) != 0 {
		t.Fatalf("got %+v", calls)
	}
}

// TestShouldGiveUpAfterAuthFailure is Task #187's pure-logic unit test for
// shouldGiveUpAfterAuthFailure's success-history judgment — no fake IMAP
// server, no store, no sleeping.
func TestShouldGiveUpAfterAuthFailure(t *testing.T) {
	cases := []struct {
		name                    string
		stopsImmediately        bool
		hasSucceededBefore      bool
		consecutiveAuthFailures int
		want                    bool
	}{
		{"stopsImmediately always gives up even with prior success", true, true, 1, true},
		{"stopsImmediately always gives up on the very first attempt", true, false, 1, true},
		{"never-succeeded credential retries below the cap", false, false, maxConsecutiveAuthFailures - 1, false},
		{"never-succeeded credential gives up at the cap", false, false, maxConsecutiveAuthFailures, true},
		{"never-succeeded credential gives up past the cap", false, false, maxConsecutiveAuthFailures + 5, true},
		{"proven credential never gives up below the cap", false, true, maxConsecutiveAuthFailures - 1, false},
		{"proven credential never gives up at the old cap", false, true, maxConsecutiveAuthFailures, false},
		{"proven credential never gives up far past the old cap", false, true, maxConsecutiveAuthFailures * 100, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := shouldGiveUpAfterAuthFailure(tc.stopsImmediately, tc.hasSucceededBefore, tc.consecutiveAuthFailures)
			if got != tc.want {
				t.Errorf("shouldGiveUpAfterAuthFailure(%v, %v, %d) = %v, want %v",
					tc.stopsImmediately, tc.hasSucceededBefore, tc.consecutiveAuthFailures, got, tc.want)
			}
		})
	}
}

// TestAuthFailureAfterPriorSuccessNeverStopsAndUsesLongBackoff is Task
// #187's regression test: a watch whose credential has authenticated
// successfully before (simulated here via store.MarkWatchConnected, rather
// than toggling the fake server mid-test — see this test's doc comment on
// why) must never reach WatchStatusStopped on a plain AUTHENTICATIONFAILED
// rejection, must keep LastConnectedAt set (proof it once worked), and must
// space its retries at Options.AuthFailureRetryInterval rather than the
// short connection-error backoff — driven down to milliseconds here so the
// test doesn't actually wait 30 minutes.
func TestAuthFailureAfterPriorSuccessNeverStopsAndUsesLongBackoff(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.RejectsLogin = true
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := New(s, sender, testLogger(), Options{
		IdleMaxWait:   3 * time.Second,
		PollInterval:  200 * time.Millisecond,
		NetworkPolicy: security.PermissiveForTesting(),
		// Small enough that several retries fit in the test's deadline,
		// large enough to clearly distinguish from the short
		// connection-error backoff (starts at 2s in production).
		AuthFailureRetryInterval: 150 * time.Millisecond,
		AuthFailureRetryCap:      1 * time.Second,
	})
	t.Cleanup(pool.Stop)

	deviceID, watchID := createWatch(t, s, port, "account-auth-fail-after-success",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "was-correct-password"},
		api.EnvironmentSandbox, "tok")
	// Simulate "this credential connected successfully earlier" without
	// racing FakeServer.RejectsLogin (a plain bool field, not guarded for
	// concurrent access — see FakeServer's doc comment) by setting it
	// before the pool ever attempts a connection.
	if err := s.MarkWatchConnected(t.Context(), watchID); err != nil {
		t.Fatal(err)
	}
	pool.AddWatch(watchID)

	// Poll for well over maxConsecutiveAuthFailures (3) worth of retries at
	// the short-backoff timescale — if this watch used the old
	// give-up-after-3 behavior, it would already be WatchStatusStopped
	// long before this deadline.
	deadline := time.Now().Add(3 * time.Second)
	var lastSummary api.WatchSummary
	sawAuthFailure := false
	for time.Now().Before(deadline) {
		summaries, err := s.ListWatchSummaries(t.Context(), deviceID)
		if err != nil {
			t.Fatal(err)
		}
		if len(summaries) != 1 {
			t.Fatalf("got %d summaries", len(summaries))
		}
		lastSummary = summaries[0]
		if lastSummary.Status == api.WatchStatusStopped {
			t.Fatalf("watch stopped despite a prior successful connection: %+v", lastSummary)
		}
		if lastSummary.LastErrorKind != nil && *lastSummary.LastErrorKind == api.ErrorKindAuthFailure {
			sawAuthFailure = true
		}
		if lastSummary.LastConnectedAt == nil {
			t.Fatalf("lastConnectedAt should stay set from the earlier MarkWatchConnected: %+v", lastSummary)
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !sawAuthFailure {
		t.Fatal("watch never recorded an auth failure at all")
	}
	if lastSummary.Status != api.WatchStatusActive {
		t.Fatalf("got %+v", lastSummary)
	}
}

func TestRemovingWatchStopsFurtherPushes(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SetInitialState(1, 2)
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := newTestPool(t, s, sender, nil)
	deviceID, watchID := createWatch(t, s, port, "account-3",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"},
		api.EnvironmentSandbox, "tok")
	pool.AddWatch(watchID)
	time.Sleep(300 * time.Millisecond)

	if _, err := s.DeleteWatch(t.Context(), watchID, deviceID); err != nil {
		t.Fatal(err)
	}
	pool.RemoveWatch(watchID)
	time.Sleep(200 * time.Millisecond)

	server.DeliverNewMail()
	time.Sleep(500 * time.Millisecond)

	if calls := sender.Calls(); len(calls) != 0 {
		t.Fatalf("got %+v", calls)
	}
}

func TestOAuthWatchAuthenticatesViaXOAuth2AndFiresPush(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SetInitialState(5, 6)
	server.ExpectedXOAuth2AccessToken = "fresh-access-token"
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	exchanger := &fakeExchanger{accessToken: "fresh-access-token"}
	pool := newTestPool(t, s, sender, exchanger)
	provider := api.ProviderGoogle
	deviceID, watchID := createWatch(t, s, port, "oauth-account",
		api.WatchAuth{Type: api.WatchAuthOAuth, Secret: "stored-refresh-token", Provider: &provider},
		api.EnvironmentSandbox, "oauth-device-token")
	pool.AddWatch(watchID)

	time.Sleep(300 * time.Millisecond)
	server.DeliverNewMail()

	calls := waitForCalls(t, sender, 1, 5*time.Second)
	if len(calls) != 1 || calls[0].Payload.AccountID != "oauth-account" {
		t.Fatalf("got %+v", calls)
	}
	exchanges := exchanger.Calls()
	if len(exchanges) == 0 || exchanges[0].Provider != api.ProviderGoogle || exchanges[0].RefreshToken != "stored-refresh-token" {
		t.Fatalf("got %+v", exchanges)
	}
	summaries, err := s.ListWatchSummaries(t.Context(), deviceID)
	if err != nil {
		t.Fatal(err)
	}
	if len(summaries) != 1 || summaries[0].Status != api.WatchStatusActive {
		t.Fatalf("got %+v", summaries)
	}
}

func TestOAuthWatchStopsImmediatelyOnInvalidGrant(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	exchanger := &fakeExchanger{err: oauth.ErrInvalidGrant}
	pool := newTestPool(t, s, sender, exchanger)
	provider := api.ProviderMicrosoft
	deviceID, watchID := createWatch(t, s, port, "oauth-dead-account",
		api.WatchAuth{Type: api.WatchAuthOAuth, Secret: "revoked-refresh-token", Provider: &provider},
		api.EnvironmentSandbox, "oauth-dead-token")
	pool.AddWatch(watchID)

	var summary *api.WatchSummary
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		summaries, err := s.ListWatchSummaries(t.Context(), deviceID)
		if err != nil {
			t.Fatal(err)
		}
		if len(summaries) == 1 && summaries[0].Status == api.WatchStatusStopped {
			summary = &summaries[0]
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if summary == nil {
		t.Fatal("watch never reached stopped status")
	}
	if summary.LastErrorKind == nil || *summary.LastErrorKind != api.ErrorKindOAuthTokenExpired {
		t.Fatalf("got %+v", summary)
	}
	// Stopped on the very first exchange attempt, not after 3 — an
	// invalid_grant never recovers by retrying.
	if exchanges := exchanger.Calls(); len(exchanges) != 1 {
		t.Fatalf("got %d exchange calls", len(exchanges))
	}
	if calls := sender.Calls(); len(calls) != 0 {
		t.Fatalf("got %+v", calls)
	}
}

// TestSharedWatchDeliversPushToEveryDeviceOnASingleConnection is Task
// #208's core end-to-end regression test: two devices registering the same
// IMAP connection identity (same host/port/username/mailbox — the ordinary
// "this mailbox account is set up on two of my devices" case) must open
// exactly ONE IMAP connection (LoginCount stays 1) yet still deliver a push
// to BOTH devices, each carrying that device's own locally-meaningful
// accountId, when new mail arrives. This is the fix for the production
// problem docs/architecture.md's pitfall "i." describes: IMAP command
// volume against the server used to scale with device count; after this
// fix it scales with distinct mailbox count instead.
func TestSharedWatchDeliversPushToEveryDeviceOnASingleConnection(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SetInitialState(5, 6)
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := newTestPool(t, s, sender, nil)

	auth := api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"}
	_, watchID := createWatch(t, s, port, "account-on-device-1", auth, api.EnvironmentSandbox, "device-1-token")

	// A second device registers the exact same connection identity
	// (host/port/username/mailbox, same createWatch helper's fixed
	// "user@example.com"/INBOX) with its own accountId — must resolve to
	// the SAME watch rather than opening a second connection.
	device2, err := s.CreateDevice(t.Context(), "device-2-token", api.EnvironmentProduction)
	if err != nil {
		t.Fatal(err)
	}
	watch2, err := s.CreateWatch(t.Context(), device2.DeviceID, api.CreateWatchRequest{
		AccountID: "account-on-device-2", ImapHost: "127.0.0.1", ImapPort: port, ImapUseTLS: false,
		ImapUsername: "user@example.com", Auth: auth, Mailbox: "INBOX",
	})
	if err != nil {
		t.Fatal(err)
	}
	if watch2.WatchID != watchID {
		t.Fatalf("expected both devices to share one watch, got %q and %q", watch2.WatchID, watchID)
	}

	pool.AddWatch(watchID)
	// Registering the second device's subscription doesn't need its own
	// AddWatch call in production (the HTTP route calls it regardless, but
	// AddWatch is a no-op for an id it's already tracking) — call it again
	// here too, matching what the route actually does, to prove that
	// doesn't start a second connection.
	pool.AddWatch(watchID)

	time.Sleep(300 * time.Millisecond)
	server.DeliverNewMail()

	calls := waitForCalls(t, sender, 2, 5*time.Second)
	if len(calls) != 2 {
		t.Fatalf("expected exactly one push per subscribed device, got %d: %+v", len(calls), calls)
	}
	byToken := map[string]pushCall{}
	for _, c := range calls {
		byToken[c.DeviceToken] = c
	}
	call1, ok1 := byToken["device-1-token"]
	call2, ok2 := byToken["device-2-token"]
	if !ok1 || !ok2 {
		t.Fatalf("expected a push to both devices, got %+v", calls)
	}
	if call1.Payload.AccountID != "account-on-device-1" || call1.Environment != api.EnvironmentSandbox {
		t.Fatalf("got %+v", call1)
	}
	if call2.Payload.AccountID != "account-on-device-2" || call2.Environment != api.EnvironmentProduction {
		t.Fatalf("got %+v", call2)
	}
	if call1.Payload.UidNext != 7 || call2.Payload.UidNext != 7 {
		t.Fatalf("expected both devices to report the same new uidNext (one shared connection), got %+v and %+v", call1, call2)
	}

	if got := server.LoginCount(); got != 1 {
		t.Fatalf("expected exactly 1 LOGIN (one shared IMAP connection for both devices), got %d", got)
	}
}

// TestDeletingOneDeviceSubscriptionKeepsPushingTheOther is Task #208's
// regression test for the "who owns the shared watch" question at delete
// time: when device A deletes its registration but device B is still
// subscribed to the same connection identity, the watch must keep running
// (and keep pushing device B) rather than stopping just because device A —
// which happened to be the one that originally created the row — is gone.
func TestDeletingOneDeviceSubscriptionKeepsPushingTheOther(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SetInitialState(1, 2)
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	pool := newTestPool(t, s, sender, nil)

	auth := api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"}
	deviceA, watchID := createWatch(t, s, port, "account-a", auth, api.EnvironmentSandbox, "device-a-token")
	deviceB, err := s.CreateDevice(t.Context(), "device-b-token", api.EnvironmentSandbox)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateWatch(t.Context(), deviceB.DeviceID, api.CreateWatchRequest{
		AccountID: "account-b", ImapHost: "127.0.0.1", ImapPort: port, ImapUseTLS: false,
		ImapUsername: "user@example.com", Auth: auth, Mailbox: "INBOX",
	}); err != nil {
		t.Fatal(err)
	}
	pool.AddWatch(watchID)
	time.Sleep(300 * time.Millisecond)

	fullyRemoved, err := s.DeleteWatch(t.Context(), watchID, deviceA)
	if err != nil {
		t.Fatal(err)
	}
	if fullyRemoved {
		t.Fatal("device B is still subscribed, the watch must not be reported as fully removed")
	}
	// Mirrors what the HTTP route does: only call RemoveWatch when the
	// store says the watch has no subscribers left at all.

	server.DeliverNewMail()
	calls := waitForCalls(t, sender, 1, 5*time.Second)
	if len(calls) != 1 {
		t.Fatalf("expected device B to still get pushed after device A's own delete, got %+v", calls)
	}
	if calls[0].DeviceToken != "device-b-token" || calls[0].Payload.AccountID != "account-b" {
		t.Fatalf("got %+v", calls[0])
	}
}

func TestPasswordWatchIsUnaffectedByOAuthSupport(t *testing.T) {
	s := newTestStore(t)
	server := imaptest.NewFakeServer()
	server.SetInitialState(1, 2)
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	sender := &fakePushSender{}
	// Configured to fail every OAuth exchange — proves a .password watch
	// never even calls it.
	exchanger := &fakeExchanger{err: oauth.ErrInvalidGrant}
	pool := newTestPool(t, s, sender, exchanger)
	_, watchID := createWatch(t, s, port, "password-account",
		api.WatchAuth{Type: api.WatchAuthPassword, Secret: "password"},
		api.EnvironmentSandbox, "password-tok")
	pool.AddWatch(watchID)

	time.Sleep(300 * time.Millisecond)
	server.DeliverNewMail()

	calls := waitForCalls(t, sender, 1, 5*time.Second)
	if len(calls) != 1 {
		t.Fatalf("got %d calls", len(calls))
	}
	if exchanges := exchanger.Calls(); len(exchanges) != 0 {
		t.Fatalf("got %+v", exchanges)
	}
}
