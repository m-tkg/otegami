package store

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"testing"

	_ "modernc.org/sqlite"

	"github.com/m-tkg/otegami-relay-go/internal/api"
	"github.com/m-tkg/otegami-relay-go/internal/cryptox"
)

// sqlOpenForLegacyFixture opens a raw *sql.DB (bypassing Store's own
// migration) so TestOpensPreTask173SchemaAndMigratesInPlace can hand-build
// an old-shape schema to migrate from.
func sqlOpenForLegacyFixture(path string) (*sql.DB, error) {
	return sql.Open("sqlite", fmt.Sprintf("file:%s?_pragma=foreign_keys(1)", path))
}

func newTestStore(t *testing.T) *Store {
	t.Helper()
	c, err := cryptox.New(make([]byte, 32))
	if err != nil {
		t.Fatal(err)
	}
	s, err := Open(":memory:", c)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestCreateDeviceAndVerify(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)

	resp, err := s.CreateDevice(ctx, "tok", api.EnvironmentSandbox)
	if err != nil {
		t.Fatal(err)
	}
	if resp.DeviceID == "" || resp.DeviceSecret == "" {
		t.Fatal("expected non-empty id/secret")
	}

	id, ok, err := s.DeviceIDForSecret(ctx, resp.DeviceSecret)
	if err != nil {
		t.Fatal(err)
	}
	if !ok || id != resp.DeviceID {
		t.Fatalf("got id=%q ok=%v", id, ok)
	}

	_, ok, err = s.DeviceIDForSecret(ctx, "wrong-secret")
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Fatal("expected wrong secret to not resolve")
	}
}

func TestUpdateDeviceToken(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	resp, _ := s.CreateDevice(ctx, "initial", api.EnvironmentSandbox)

	if err := s.UpdateDeviceToken(ctx, resp.DeviceID, "rotated", api.EnvironmentProduction); err != nil {
		t.Fatal(err)
	}
	target, err := s.PushTarget(ctx, resp.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	if target == nil || target.ApnsToken != "rotated" || target.Environment != api.EnvironmentProduction {
		t.Fatalf("got %+v", target)
	}

	if err := s.UpdateDeviceToken(ctx, "no-such-device", "x", api.EnvironmentSandbox); err != ErrDeviceNotFound {
		t.Fatalf("got %v", err)
	}
}

func TestCreateWatchEncryptsAtRest(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	device, _ := s.CreateDevice(ctx, "tok", api.EnvironmentSandbox)

	req := api.CreateWatchRequest{
		AccountID:    "account-1",
		ImapHost:     "203.0.113.10",
		ImapPort:     993,
		ImapUseTLS:   true,
		ImapUsername: "user@example.com",
		Auth:         api.WatchAuth{Type: api.WatchAuthPassword, Secret: "app-password"},
		Mailbox:      "INBOX",
	}
	resp, err := s.CreateWatch(ctx, device.DeviceID, req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.AccountID != "account-1" || resp.Mailbox != "INBOX" {
		t.Fatalf("got %+v", resp)
	}

	records, err := s.ListWatches(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].Secret != "app-password" {
		t.Fatalf("got %+v", records)
	}

	raw, ok, err := s.RawEncryptedSecretForTesting(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("expected a row")
	}
	if raw == "app-password" {
		t.Fatal("plaintext leaked to storage")
	}
}

func TestCreateOAuthWatchPersistsProvider(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	device, _ := s.CreateDevice(ctx, "tok", api.EnvironmentSandbox)

	provider := api.ProviderGoogle
	req := api.CreateWatchRequest{
		AccountID:    "gmail-account",
		ImapHost:     "203.0.113.10",
		ImapPort:     993,
		ImapUseTLS:   true,
		ImapUsername: "user@gmail.example.test",
		Auth:         api.WatchAuth{Type: api.WatchAuthOAuth, Secret: "a-refresh-token", Provider: &provider},
		Mailbox:      "INBOX",
	}
	if _, err := s.CreateWatch(ctx, device.DeviceID, req); err != nil {
		t.Fatal(err)
	}
	records, err := s.ListWatches(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 {
		t.Fatalf("got %d records", len(records))
	}
	r := records[0]
	if r.AuthType != api.WatchAuthOAuth || r.Provider == nil || *r.Provider != api.ProviderGoogle || r.Secret != "a-refresh-token" {
		t.Fatalf("got %+v", r)
	}
}

func TestDeleteWatchScopedToDevice(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	owner, _ := s.CreateDevice(ctx, "tok1", api.EnvironmentSandbox)
	intruder, _ := s.CreateDevice(ctx, "tok2", api.EnvironmentSandbox)

	req := api.CreateWatchRequest{
		AccountID: "a1", ImapHost: "203.0.113.10", ImapPort: 993, ImapUseTLS: true,
		ImapUsername: "u@example.com", Auth: api.WatchAuth{Type: api.WatchAuthPassword, Secret: "pw"}, Mailbox: "INBOX",
	}
	resp, err := s.CreateWatch(ctx, owner.DeviceID, req)
	if err != nil {
		t.Fatal(err)
	}

	if err := s.DeleteWatch(ctx, resp.WatchID, intruder.DeviceID); err != ErrWatchNotFound {
		t.Fatalf("expected ErrWatchNotFound, got %v", err)
	}
	records, _ := s.ListWatches(ctx)
	if len(records) != 1 {
		t.Fatal("watch should not have been deleted by a non-owning device")
	}

	if err := s.DeleteWatch(ctx, resp.WatchID, owner.DeviceID); err != nil {
		t.Fatal(err)
	}
	records, _ = s.ListWatches(ctx)
	if len(records) != 0 {
		t.Fatal("watch should be gone")
	}
}

func TestListWatchSummariesScopedAndCredentialFree(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	owner, _ := s.CreateDevice(ctx, "tok1", api.EnvironmentSandbox)
	other, _ := s.CreateDevice(ctx, "tok2", api.EnvironmentSandbox)

	mk := func(accountID, username string) api.CreateWatchRequest {
		return api.CreateWatchRequest{
			AccountID: accountID, ImapHost: "203.0.113.10", ImapPort: 993, ImapUseTLS: true,
			ImapUsername: username, Auth: api.WatchAuth{Type: api.WatchAuthPassword, Secret: "app-password"}, Mailbox: "INBOX",
		}
	}
	if _, err := s.CreateWatch(ctx, owner.DeviceID, mk("owner-account", "u1@example.com")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateWatch(ctx, other.DeviceID, mk("other-account", "u2@example.com")); err != nil {
		t.Fatal(err)
	}

	summaries, err := s.ListWatchSummaries(ctx, owner.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	if len(summaries) != 1 || summaries[0].AccountID != "owner-account" {
		t.Fatalf("got %+v", summaries)
	}
	if summaries[0].Status != api.WatchStatusActive {
		t.Fatalf("expected default status active, got %v", summaries[0].Status)
	}
}

func TestMarkWatchConnectedAndRecordError(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	device, _ := s.CreateDevice(ctx, "tok", api.EnvironmentSandbox)
	resp, _ := s.CreateWatch(ctx, device.DeviceID, api.CreateWatchRequest{
		AccountID: "a1", ImapHost: "203.0.113.10", ImapPort: 993, ImapUseTLS: true,
		ImapUsername: "u@example.com", Auth: api.WatchAuth{Type: api.WatchAuthPassword, Secret: "pw"}, Mailbox: "INBOX",
	})

	if err := s.RecordWatchError(ctx, resp.WatchID, api.ErrorKindAuthFailure, true); err != nil {
		t.Fatal(err)
	}
	summaries, _ := s.ListWatchSummaries(ctx, device.DeviceID)
	if summaries[0].Status != api.WatchStatusStopped || summaries[0].LastErrorKind == nil || *summaries[0].LastErrorKind != api.ErrorKindAuthFailure {
		t.Fatalf("got %+v", summaries[0])
	}

	if err := s.MarkWatchConnected(ctx, resp.WatchID); err != nil {
		t.Fatal(err)
	}
	summaries, _ = s.ListWatchSummaries(ctx, device.DeviceID)
	if summaries[0].Status != api.WatchStatusActive || summaries[0].LastErrorKind != nil || summaries[0].LastConnectedAt == nil {
		t.Fatalf("got %+v", summaries[0])
	}
}

// TestOpensExistingSwiftDatabaseSchema simulates a database file created
// by the Swift relay's migrations (same DDL, hand-copied from
// RelayStore.migrate) — the Go relay must open it and read pre-existing
// rows without any explicit migration step, per Task #180's compatibility
// requirement.
func TestOpensPreTask173SchemaAndMigratesInPlace(t *testing.T) {
	ctx := context.Background()
	c, err := cryptox.New(make([]byte, 32))
	if err != nil {
		t.Fatal(err)
	}

	// Build a raw pre-#173 schema (no status/lastConnectedAt/lastErrorKind/
	// lastErrorAt/authProvider columns) directly via database/sql, bypassing
	// Store.Open (which always runs the up-to-date migration).
	dbPath := t.TempDir() + "/legacy.sqlite"
	raw, err := sqlOpenForLegacyFixture(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := raw.ExecContext(ctx, `CREATE TABLE device (
		id TEXT PRIMARY KEY, secretHash TEXT NOT NULL, apnsToken TEXT NOT NULL DEFAULT '',
		environment TEXT NOT NULL DEFAULT 'sandbox', createdAt TEXT NOT NULL
	)`); err != nil {
		t.Fatal(err)
	}
	if _, err := raw.ExecContext(ctx, `CREATE TABLE watch (
		id TEXT PRIMARY KEY, deviceId TEXT NOT NULL, accountId TEXT NOT NULL,
		imapHost TEXT NOT NULL, imapPort INTEGER NOT NULL, imapUseTLS INTEGER NOT NULL,
		imapUsername TEXT NOT NULL, authType TEXT NOT NULL, encryptedSecret BLOB NOT NULL,
		mailbox TEXT NOT NULL, createdAt TEXT NOT NULL
	)`); err != nil {
		t.Fatal(err)
	}
	encrypted, err := c.Encrypt("legacy-password")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := raw.ExecContext(ctx, `INSERT INTO device (id, secretHash, apnsToken, environment, createdAt) VALUES (?,?,?,?,?)`,
		"dev1", HashSecret("secret1"), "apnstoken", "sandbox", "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if _, err := raw.ExecContext(ctx, `INSERT INTO watch (id, deviceId, accountId, imapHost, imapPort, imapUseTLS, imapUsername, authType, encryptedSecret, mailbox, createdAt) VALUES (?,?,?,?,?,?,?,?,?,?,?)`,
		"watch1", "dev1", "legacy-account", "legacy.example.com", 993, 1, "user@example.com", "password", encrypted, "INBOX", "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	raw.Close()

	// Now open with the real Store — it must migrate in place and still
	// read the pre-existing row correctly.
	s, err := Open(dbPath, c)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	records, err := s.ListWatches(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].Secret != "legacy-password" || records[0].AccountID != "legacy-account" {
		t.Fatalf("got %+v", records)
	}

	summaries, err := s.ListWatchSummaries(ctx, "dev1")
	if err != nil {
		t.Fatal(err)
	}
	if len(summaries) != 1 || summaries[0].Status != api.WatchStatusActive {
		t.Fatalf("expected legacy row to default to active status, got %+v", summaries)
	}
}

// TestOpensRealSwiftProducedDatabase is the strongest compatibility check
// in this port (Task #180's "暗号化互換の検証結果 (最重要)" requirement):
// testdata/legacy-swift-relay.sqlite is not a hand-built fixture — it was
// produced by actually running the real Swift relay
// (server/otegami-relay, unmodified) against a fresh RELAY_MASTER_KEY,
// then registering a device via `POST /v1/devices` and creating one
// `.password` and one `.oauth` watch via `POST /v1/watches` over real
// HTTP, exactly as a production deployment would. The master key below is
// a one-off test key generated for this fixture only (`openssl rand
// -base64 32`), never used for anything else — safe to commit.
//
// This test opens that file with the Go store (which runs the same
// no-op-if-current migration path a production upgrade would) and checks
// every credential decrypts to the exact plaintext that was sent to the
// Swift relay's HTTP API, proving AES-256-GCM compatibility end-to-end
// (not just CredentialCrypto in isolation — the whole
// createDevice/createWatch/listWatches path).
func TestOpensRealSwiftProducedDatabase(t *testing.T) {
	ctx := context.Background()
	const legacyMasterKeyBase64 = "YlODfTPvnCzfCN2zUG2/NOyixdoLyC2XiT4AMyGLCyQ="

	// Copy the fixture to a temp path — Store.Open/migrate may write to it
	// (WAL/journal files), and testdata/ should stay pristine in the repo.
	src, err := os.ReadFile("testdata/legacy-swift-relay.sqlite")
	if err != nil {
		t.Fatal(err)
	}
	dbPath := t.TempDir() + "/legacy-swift-relay.sqlite"
	if err := os.WriteFile(dbPath, src, 0o600); err != nil {
		t.Fatal(err)
	}

	crypto, err := cryptox.NewFromBase64Key(legacyMasterKeyBase64)
	if err != nil {
		t.Fatal(err)
	}
	s, err := Open(dbPath, crypto)
	if err != nil {
		t.Fatalf("opening a real Swift-produced database failed: %v", err)
	}
	defer s.Close()

	records, err := s.ListWatches(ctx)
	if err != nil {
		t.Fatalf("listing watches from a real Swift-produced database failed: %v", err)
	}
	if len(records) != 2 {
		t.Fatalf("expected 2 watches, got %d: %+v", len(records), records)
	}

	byAccountID := map[string]WatchRecord{}
	for _, r := range records {
		byAccountID[r.AccountID] = r
	}

	passwordWatch, ok := byAccountID["legacy-account-1"]
	if !ok {
		t.Fatal("missing legacy-account-1 watch")
	}
	if passwordWatch.AuthType != api.WatchAuthPassword {
		t.Fatalf("got authType %v", passwordWatch.AuthType)
	}
	if passwordWatch.Secret != "real-imap-app-password-123" {
		t.Fatalf("decrypted secret mismatch: got %q", passwordWatch.Secret)
	}
	if passwordWatch.ImapHost != "203.0.113.10" || passwordWatch.ImapUsername != "user@example.com" {
		t.Fatalf("got %+v", passwordWatch)
	}

	oauthWatch, ok := byAccountID["legacy-gmail-account"]
	if !ok {
		t.Fatal("missing legacy-gmail-account watch")
	}
	if oauthWatch.AuthType != api.WatchAuthOAuth {
		t.Fatalf("got authType %v", oauthWatch.AuthType)
	}
	if oauthWatch.Provider == nil || *oauthWatch.Provider != api.ProviderGoogle {
		t.Fatalf("got provider %+v", oauthWatch.Provider)
	}
	if oauthWatch.Secret != "1//legacy-refresh-token-xyz" {
		t.Fatalf("decrypted refresh token mismatch: got %q", oauthWatch.Secret)
	}

	// Confirm a device secret also round-trips end to end: the device row
	// stores only a SHA-256 hash (never the plaintext secret from
	// registration time), so this checks the hash comparison path instead.
	deviceID, ok, err := s.DeviceIDForSecret(ctx, "jxkmqQKsmWo3O-BEOa5DfRgBfXalG3WNBshcUuiTH-o")
	if err != nil {
		t.Fatal(err)
	}
	if !ok || deviceID != "ivwEgjYel_znk2CwH7U-4A" {
		t.Fatalf("got deviceID=%q ok=%v", deviceID, ok)
	}
}
