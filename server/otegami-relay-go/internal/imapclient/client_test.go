package imapclient

import (
	"errors"
	"testing"
	"time"

	"github.com/m-tkg/otegami-relay-go/internal/imaptest"
	"github.com/m-tkg/otegami-relay-go/internal/security"
)

func connectToFake(t *testing.T, server *imaptest.FakeServer) *Client {
	t.Helper()
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(server.Stop)
	c := New()
	if err := c.Connect("127.0.0.1", port, false, 5*time.Second, security.PermissiveForTesting()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func TestLoginSelectStatusFlow(t *testing.T) {
	server := imaptest.NewFakeServer()
	server.SetInitialState(5, 6)
	c := connectToFake(t, server)

	if err := c.Login("user@example.com", "password"); err != nil {
		t.Fatal(err)
	}
	result, err := c.Select("INBOX")
	if err != nil {
		t.Fatal(err)
	}
	if result.Exists != 5 || result.UidNext == nil || *result.UidNext != 6 {
		t.Fatalf("got %+v", result)
	}
	uidNext, err := c.StatusUIDNext("INBOX")
	if err != nil {
		t.Fatal(err)
	}
	if uidNext != 6 {
		t.Fatalf("got %d", uidNext)
	}
	idle, err := c.CapabilitiesIncludeIdle()
	if err != nil {
		t.Fatal(err)
	}
	if !idle {
		t.Fatal("expected IDLE capability")
	}
	if err := c.Logout(); err != nil {
		t.Fatal(err)
	}
}

func TestLoginRejectedSurfacesCommandFailed(t *testing.T) {
	server := imaptest.NewFakeServer()
	server.RejectsLogin = true
	c := connectToFake(t, server)

	err := c.Login("user@example.com", "wrong")
	var cmdErr *CommandFailedError
	if !errors.As(err, &cmdErr) {
		t.Fatalf("expected CommandFailedError, got %v", err)
	}
}

func TestIdleWakesOnNewMail(t *testing.T) {
	server := imaptest.NewFakeServer()
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Select("INBOX"); err != nil {
		t.Fatal(err)
	}

	go func() {
		time.Sleep(200 * time.Millisecond)
		server.DeliverNewMail()
	}()
	start := time.Now()
	sawExists, err := c.Idle("INBOX", 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if !sawExists {
		t.Fatal("expected IDLE to observe EXISTS")
	}
	if time.Since(start) > 5*time.Second {
		t.Fatal("IDLE should have woken promptly, not on its own deadline")
	}
	// The connection must remain usable for the STATUS re-check.
	uidNext, err := c.StatusUIDNext("INBOX")
	if err != nil {
		t.Fatal(err)
	}
	if uidNext != 7 {
		t.Fatalf("got %d", uidNext)
	}
}

func TestIdleTimeoutLeavesConnectionUsable(t *testing.T) {
	// Regression parity with the Swift LineBuffer bug (docs/verify.md
	// "otegami-relay: IDLE がタイムアウトで接続を壊す"): an ordinary IDLE
	// timeout (quiet mailbox) must not poison the connection.
	server := imaptest.NewFakeServer()
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Select("INBOX"); err != nil {
		t.Fatal(err)
	}

	sawExists, err := c.Idle("INBOX", 300*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if sawExists {
		t.Fatal("no mail was delivered")
	}
	// Connection survives; a later IDLE still notices mail.
	go func() {
		time.Sleep(100 * time.Millisecond)
		server.DeliverNewMail()
	}()
	sawExists, err = c.Idle("INBOX", 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if !sawExists {
		t.Fatal("expected the post-timeout IDLE to observe EXISTS")
	}
}

func TestXOAuth2Success(t *testing.T) {
	server := imaptest.NewFakeServer()
	server.ExpectedXOAuth2AccessToken = "fresh-access-token"
	c := connectToFake(t, server)
	if err := c.AuthenticateXOAuth2("user@gmail.example.test", "fresh-access-token"); err != nil {
		t.Fatal(err)
	}
}

func TestXOAuth2RejectedTokenGetsTaggedFailureAfterContinuation(t *testing.T) {
	server := imaptest.NewFakeServer()
	server.ExpectedXOAuth2AccessToken = "the-only-valid-token"
	c := connectToFake(t, server)
	err := c.AuthenticateXOAuth2("user@gmail.example.test", "stale-token")
	var cmdErr *CommandFailedError
	if !errors.As(err, &cmdErr) {
		t.Fatalf("expected CommandFailedError after the RFC 7628 §3.2.2 dance, got %v", err)
	}
}

// --- CLAUDE-SECURITY F3: control-character rejection ---

func TestQuotedRejectsControlCharacters(t *testing.T) {
	for _, value := range []string{
		"a\r\nRCPT TO:<attacker@evil.test>",
		"a\nb",
		"a\rb",
		"a\x00b",
		"a\x7Fb", // DEL
		"a\x01b", // arbitrary C0 control character
	} {
		if _, err := quoted(value); err == nil {
			t.Fatalf("expected %q to be rejected", value)
		}
	}
}

func TestQuotedAcceptsOrdinaryValuesAndEscapes(t *testing.T) {
	for value, want := range map[string]string{
		"user@example.com":  `"user@example.com"`,
		"app-password-123!": `"app-password-123!"`,
		"INBOX":             `"INBOX"`,
		"受信トレイ":             `"受信トレイ"`, // non-ASCII is fine
		`pa"ss\word`:        `"pa\"ss\\word"`,
	} {
		got, err := quoted(value)
		if err != nil {
			t.Fatalf("%q: %v", value, err)
		}
		if got != want {
			t.Fatalf("%q: got %q, want %q", value, got, want)
		}
	}
}

func TestLoginRejectsCRLFInCredentialsWithoutWriting(t *testing.T) {
	c := New() // never connected — a write would fail with ErrNotConnected instead
	err := c.Login("user\r\nX1 LOGOUT", "pw")
	var ctrlErr *security.ErrInvalidControlCharacters
	if !errors.As(err, &ctrlErr) {
		t.Fatalf("expected control-character rejection before any write, got %v", err)
	}
}

// --- CLAUDE-SECURITY F4/F8: response-size limits ---

func TestFloodingUntaggedLinesTripsBound(t *testing.T) {
	server := &imaptest.FloodingServer{Mode: imaptest.UntaggedLineFlood}
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	c := New()
	if err := c.Connect("127.0.0.1", port, false, 5*time.Second, security.PermissiveForTesting()); err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	if err := c.Login("user", "pw"); !errors.Is(err, ErrResponseTooLarge) {
		t.Fatalf("expected ErrResponseTooLarge, got %v", err)
	}
}

func TestOversizedLineTripsLengthBound(t *testing.T) {
	server := &imaptest.FloodingServer{Mode: imaptest.OversizedLine}
	port, err := server.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Stop()

	c := New()
	// The oversized, never-terminated "line" is sent as soon as the
	// connection is established, so Connect itself (which waits for the
	// untagged greeting) observes the length bound.
	err = c.Connect("127.0.0.1", port, false, 5*time.Second, security.PermissiveForTesting())
	if !errors.Is(err, ErrResponseTooLarge) {
		t.Fatalf("expected ErrResponseTooLarge, got %v", err)
	}
}

func TestConcurrentCloseUnblocksIdle(t *testing.T) {
	// The watcher pool closes the client from another goroutine (via
	// context.AfterFunc) to promptly stop a removed watch mid-IDLE.
	server := imaptest.NewFakeServer()
	c := connectToFake(t, server)
	if err := c.Login("u", "p"); err != nil {
		t.Fatal(err)
	}
	go func() {
		time.Sleep(200 * time.Millisecond)
		c.Close()
	}()
	start := time.Now()
	_, err := c.Idle("INBOX", 30*time.Second)
	if err == nil {
		t.Fatal("expected the concurrent Close to fail the IDLE")
	}
	if time.Since(start) > 5*time.Second {
		t.Fatal("Close should have unblocked the IDLE promptly")
	}
}
