package watcher

import (
	"bytes"
	"encoding/json"
	"fmt"
	"mime"
	"mime/quotedprintable"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/m-tkg/otegami-relay-go/internal/api"
	"github.com/m-tkg/otegami-relay-go/internal/httpapi"
	"github.com/m-tkg/otegami-relay-go/internal/security"
)

// Opt-in: skipped (not failed) unless OTEGAMI_TEST_IMAP_HOST is set,
// matching the repo-wide convention (docs/verify.md). Run against
// dev/mailstack with:
//
//	make mailstack-up
//	cd server/otegami-relay-go && OTEGAMI_TEST_IMAP_HOST=localhost go test ./internal/watcher/ -run RealDovecot -v
//	make mailstack-down
//
// Why this exists in addition to the imaptest.FakeServer-based tests: the
// Swift port's FakeIMAPServer-based unit tests passed the entire time a
// real production bug shipped (an IDLE timeout poisoning the connection —
// docs/verify.md's "otegami-relay: IDLE がタイムアウトで接続を壊す"). A real
// Dovecot exercises (a) an IDLE actually reaching its deadline with the
// connection surviving for the next command, and (b) Dovecot's real
// "* N EXISTS" + separate "* 0 RECENT" untagged-line shape on new mail.

type imapTestEnv struct {
	host, username, password string
	port                     int
}

func imapEnvironment() *imapTestEnv {
	host := os.Getenv("OTEGAMI_TEST_IMAP_HOST")
	if host == "" {
		return nil
	}
	port := 1143
	if raw := os.Getenv("OTEGAMI_TEST_IMAP_PORT"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil {
			port = parsed
		}
	}
	username := os.Getenv("OTEGAMI_TEST_IMAP_USER")
	if username == "" {
		username = "test1@otegami.test"
	}
	password := os.Getenv("OTEGAMI_TEST_IMAP_PASSWORD")
	if password == "" {
		password = "test1234"
	}
	return &imapTestEnv{host: host, port: port, username: username, password: password}
}

// mailstackDir mirrors DoveadmHelper.mailstackDirectory — dev/mailstack's
// directory, derived from this source file's own path, overridable via
// OTEGAMI_TEST_MAILSTACK_DIR.
func mailstackDir(t *testing.T) string {
	if override := os.Getenv("OTEGAMI_TEST_MAILSTACK_DIR"); override != "" {
		return override
	}
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not determine source file path")
	}
	// thisFile: .../server/otegami-relay-go/internal/watcher/dovecot_integration_test.go
	repoRoot := filepath.Dir(filepath.Dir(filepath.Dir(filepath.Dir(filepath.Dir(thisFile)))))
	return filepath.Join(repoRoot, "dev", "mailstack")
}

// doveadmSave mirrors DoveadmHelper.save — `docker compose exec -T dovecot
// doveadm save -u <user> -m INBOX` with the message on stdin, standing in
// for "another IMAP client just delivered mail".
func doveadmSave(t *testing.T, dir, user, content string) {
	t.Helper()
	cmd := exec.Command("docker", "compose", "exec", "-T", "dovecot", "doveadm", "save", "-u", user, "-m", "INBOX")
	cmd.Dir = dir
	cmd.Stdin = strings.NewReader(content)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("doveadm save failed: %v\n%s", err, out)
	}
}

// restoreStandardFixtures mirrors DoveadmHelper.restoreStandardFixtures —
// re-runs dev/mailstack/seed/seed.sh so injected mail doesn't leak into
// other suites.
func restoreStandardFixtures(t *testing.T, dir string) {
	t.Helper()
	cmd := exec.Command("bash", "seed/seed.sh")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Logf("seed restore failed (non-fatal): %v\n%s", err, out)
	}
}

func probeMessage(user, subject string) string {
	return "From: Integration Test <integration-test@otegami.test>\r\n" +
		"To: " + user + "\r\n" +
		"Subject: " + subject + "\r\n" +
		"Date: Mon, 1 Jan 2024 00:00:00 +0000\r\n" +
		"Content-Type: text/plain; charset=utf-8\r\n" +
		"\r\n" +
		"probe body\r\n"
}

// multipartQuotedPrintableJapaneseProbeMessage builds an RFC 822 message
// with an RFC 2047-encoded Japanese subject and a multipart/alternative
// body whose text/plain part is quoted-printable-encoded — the exact
// combination RELAY_CONTENT_PREVIEW's preview_parse.go
// (internal/imapclient) exists to decode, built here with the stdlib's own
// encoders (not hand-computed base64/QP) so this test proves round-trip
// correctness against a real Dovecot rather than against this package's
// own assumptions about the wire format.
func multipartQuotedPrintableJapaneseProbeMessage(t *testing.T, user, subject, plainBody string) string {
	t.Helper()
	encodedSubject := mime.BEncoding.Encode("UTF-8", subject)

	var qp bytes.Buffer
	w := quotedprintable.NewWriter(&qp)
	if _, err := w.Write([]byte(plainBody)); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}

	const boundary = "OTEGAMI-INTEGRATION-TEST-BOUNDARY"
	return fmt.Sprintf(
		"From: Integration Test <integration-test@otegami.test>\r\n"+
			"To: %s\r\n"+
			"Subject: %s\r\n"+
			"Date: Mon, 1 Jan 2024 00:00:00 +0000\r\n"+
			"MIME-Version: 1.0\r\n"+
			"Content-Type: multipart/alternative; boundary=\"%s\"\r\n"+
			"\r\n"+
			"--%s\r\n"+
			"Content-Type: text/plain; charset=utf-8\r\n"+
			"Content-Transfer-Encoding: quoted-printable\r\n"+
			"\r\n"+
			"%s\r\n"+
			"--%s\r\n"+
			"Content-Type: text/html; charset=utf-8\r\n"+
			"\r\n"+
			"<p>html fallback, must not be preferred over the text/plain part above</p>\r\n"+
			"--%s--\r\n",
		user, encodedSubject, boundary, boundary, qp.String(), boundary, boundary,
	)
}

// TestRealDovecotContentPreviewFetchesDecodesAndServesPreview is
// RELAY_CONTENT_PREVIEW's (opt-in, Phase 2) end-to-end check against a
// real Dovecot: IDLE detects doveadm-delivered mail, the watcher pool
// fetches and decodes a multipart/Japanese-subject/quoted-printable
// message on the same connection, caches it, attaches it to the push
// payload, and serves it back out through the real GET /v1/messages HTTP
// handler — not just this package's own store round-trip, closing the gap
// between "preview_parse.go's unit tests pass" and "a real IMAP server's
// exact FETCH response shape decodes correctly end to end", the same
// rationale as this file's other RealDovecot tests (see this file's doc
// comment).
func TestRealDovecotContentPreviewFetchesDecodesAndServesPreview(t *testing.T) {
	env := imapEnvironment()
	if env == nil {
		t.Skip("set OTEGAMI_TEST_IMAP_HOST to run")
	}
	dir := mailstackDir(t)
	defer restoreStandardFixtures(t, dir)

	s := newTestStore(t)
	sender := &fakePushSender{}
	pool := New(s, sender, testLogger(), Options{
		IdleMaxWait:           120 * time.Second,
		PollInterval:          200 * time.Millisecond,
		NetworkPolicy:         security.PermissiveForTesting(),
		ContentPreviewEnabled: true,
	})
	t.Cleanup(pool.Stop)

	device, err := s.CreateDevice(t.Context(), "real-dovecot-preview-token", api.EnvironmentSandbox)
	if err != nil {
		t.Fatal(err)
	}
	watch, err := s.CreateWatch(t.Context(), device.DeviceID, api.CreateWatchRequest{
		AccountID:    "real-dovecot-preview-account",
		ImapHost:     env.host,
		ImapPort:     env.port,
		ImapUseTLS:   false,
		ImapUsername: env.username,
		Auth:         api.WatchAuth{Type: api.WatchAuthPassword, Secret: env.password},
		Mailbox:      "INBOX",
	})
	if err != nil {
		t.Fatal(err)
	}
	pool.AddWatch(watch.WatchID)

	// Give the loop time to connect, LOGIN, SELECT, and enter IDLE before
	// another client delivers mail.
	time.Sleep(2 * time.Second)

	const japaneseSubject = "日本語の件名テスト"
	const plainBody = "こんにちは、プレビューのテストです。"
	doveadmSave(t, dir, env.username, multipartQuotedPrintableJapaneseProbeMessage(t, env.username, japaneseSubject, plainBody))

	calls := waitForCalls(t, sender, 1, 30*time.Second)
	if len(calls) != 1 {
		t.Fatalf("got %d calls: %+v", len(calls), calls)
	}
	payload := calls[0].Payload
	if payload.AccountID != "real-dovecot-preview-account" {
		t.Fatalf("got %+v", payload)
	}
	if payload.LatestSubject != japaneseSubject {
		t.Fatalf("got latestSubject=%q, want %q", payload.LatestSubject, japaneseSubject)
	}
	if payload.LatestFromAddress != "integration-test@otegami.test" {
		t.Fatalf("got %+v", payload)
	}

	previews, err := s.MessagePreviewsSince(t.Context(), watch.WatchID, 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(previews) != 1 {
		t.Fatalf("got %d cached previews: %+v", len(previews), previews)
	}
	if previews[0].Subject != japaneseSubject {
		t.Fatalf("got cached subject=%q, want %q", previews[0].Subject, japaneseSubject)
	}
	if !strings.Contains(previews[0].BodyPreview, "こんにちは") {
		t.Fatalf("expected the quoted-printable-decoded text/plain part in the cached preview, got %q", previews[0].BodyPreview)
	}
	if strings.Contains(previews[0].BodyPreview, "html fallback") {
		t.Fatalf("text/plain must be preferred over text/html in a multipart/alternative body, got %q", previews[0].BodyPreview)
	}

	// Close the loop through the real HTTP handler, not just the store —
	// this is what actually proves the wire-format contract Phase 3's app
	// implementation will rely on.
	router := httpapi.NewRouter(s, pool, security.PermissiveForTesting(), "", true, testLogger())
	req := httptest.NewRequest(http.MethodGet, "/v1/messages?accountId=real-dovecot-preview-account", nil)
	req.Header.Set("Authorization", "Bearer "+device.DeviceSecret)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /v1/messages: got %d: %s", rec.Code, rec.Body.String())
	}
	var messages []api.MessagePreviewSummary
	if err := json.Unmarshal(rec.Body.Bytes(), &messages); err != nil {
		t.Fatal(err)
	}
	if len(messages) != 1 || messages[0].Subject != japaneseSubject {
		t.Fatalf("got %+v", messages)
	}
	if messages[0].From.Address != "integration-test@otegami.test" {
		t.Fatalf("got %+v", messages[0])
	}
	if !strings.Contains(messages[0].BodyPreview, "こんにちは") {
		t.Fatalf("got %+v", messages[0])
	}

	pool.RemoveWatch(watch.WatchID)
}

func TestRealDovecotIdleDetectsNewMail(t *testing.T) {
	env := imapEnvironment()
	if env == nil {
		t.Skip("set OTEGAMI_TEST_IMAP_HOST to run")
	}
	dir := mailstackDir(t)
	defer restoreStandardFixtures(t, dir)

	s := newTestStore(t)
	sender := &fakePushSender{}
	pool := New(s, sender, testLogger(), Options{
		IdleMaxWait:  120 * time.Second,
		PollInterval: 200 * time.Millisecond,
		// Dials dev/mailstack's Dovecot on localhost — a developer's own
		// machine, not the SSRF threat security.Strict() defends against.
		NetworkPolicy: security.PermissiveForTesting(),
	})
	t.Cleanup(pool.Stop)

	device, err := s.CreateDevice(t.Context(), "real-dovecot-token", api.EnvironmentSandbox)
	if err != nil {
		t.Fatal(err)
	}
	watch, err := s.CreateWatch(t.Context(), device.DeviceID, api.CreateWatchRequest{
		AccountID:    "real-dovecot-account",
		ImapHost:     env.host,
		ImapPort:     env.port,
		ImapUseTLS:   false,
		ImapUsername: env.username,
		Auth:         api.WatchAuth{Type: api.WatchAuthPassword, Secret: env.password},
		Mailbox:      "INBOX",
	})
	if err != nil {
		t.Fatal(err)
	}
	pool.AddWatch(watch.WatchID)

	// Give the loop time to connect, LOGIN, SELECT, and enter IDLE before
	// another client delivers mail.
	time.Sleep(2 * time.Second)
	doveadmSave(t, dir, env.username, probeMessage(env.username, "relay-go RealDovecot IDLE probe"))

	calls := waitForCalls(t, sender, 1, 30*time.Second)
	if len(calls) != 1 {
		t.Fatalf("got %d calls: %+v", len(calls), calls)
	}
	if calls[0].Payload.AccountID != "real-dovecot-account" {
		t.Fatalf("got %+v", calls[0].Payload)
	}
	pool.RemoveWatch(watch.WatchID)
}

func TestRealDovecotIdleTimeoutDoesNotBreakSubsequentDetection(t *testing.T) {
	env := imapEnvironment()
	if env == nil {
		t.Skip("set OTEGAMI_TEST_IMAP_HOST to run")
	}
	dir := mailstackDir(t)
	defer restoreStandardFixtures(t, dir)

	s := newTestStore(t)
	sender := &fakePushSender{}
	// A deliberately short IdleMaxWait so the very first IDLE cycle times
	// out (no mail arrives in time) before we deliver anything — the RFC
	// 2177 "reissue IDLE" case that used to poison the Swift client's
	// connection permanently.
	pool := New(s, sender, testLogger(), Options{
		IdleMaxWait:   3 * time.Second,
		PollInterval:  200 * time.Millisecond,
		NetworkPolicy: security.PermissiveForTesting(),
	})
	t.Cleanup(pool.Stop)

	device, err := s.CreateDevice(t.Context(), "real-dovecot-timeout-token", api.EnvironmentSandbox)
	if err != nil {
		t.Fatal(err)
	}
	watch, err := s.CreateWatch(t.Context(), device.DeviceID, api.CreateWatchRequest{
		AccountID:    "real-dovecot-timeout-account",
		ImapHost:     env.host,
		ImapPort:     env.port,
		ImapUseTLS:   false,
		ImapUsername: env.username,
		Auth:         api.WatchAuth{Type: api.WatchAuthPassword, Secret: env.password},
		Mailbox:      "INBOX",
	})
	if err != nil {
		t.Fatal(err)
	}
	pool.AddWatch(watch.WatchID)

	// Let at least one full IDLE timeout happen with no mail delivered.
	time.Sleep(6 * time.Second)

	doveadmSave(t, dir, env.username, probeMessage(env.username, "relay-go RealDovecot post-timeout probe"))

	calls := waitForCalls(t, sender, 1, 30*time.Second)
	if len(calls) != 1 {
		t.Fatalf("got %d calls: %+v", len(calls), calls)
	}
	if calls[0].Payload.AccountID != "real-dovecot-timeout-account" {
		t.Fatalf("got %+v", calls[0].Payload)
	}
	pool.RemoveWatch(watch.WatchID)
}
