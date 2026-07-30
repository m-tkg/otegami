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

	if err := s.DeleteWatch(t.Context(), watchID, deviceID); err != nil {
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
