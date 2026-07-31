package store

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"sync"
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

	if _, err := s.DeleteWatch(ctx, resp.WatchID, intruder.DeviceID); err != ErrWatchNotFound {
		t.Fatalf("expected ErrWatchNotFound, got %v", err)
	}
	records, _ := s.ListWatches(ctx)
	if len(records) != 1 {
		t.Fatal("watch should not have been deleted by a non-owning device")
	}

	fullyRemoved, err := s.DeleteWatch(ctx, resp.WatchID, owner.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	if !fullyRemoved {
		t.Fatal("expected the watch's only subscriber deleting it to fully remove the watch")
	}
	records, _ = s.ListWatches(ctx)
	if len(records) != 0 {
		t.Fatal("watch should be gone")
	}
}

// TestCreateWatchDedupesSameConnectionIdentityAcrossDevices is Task #208's
// core regression test: two devices registering the exact same IMAP
// connection identity (host/port/TLS/username/authType/mailbox) — the
// ordinary "the same mailbox account set up on two of the user's devices"
// case — must share one `watch` row (one IMAP connection) rather than
// getting one each, so the relay's command volume against the IMAP server
// doesn't scale with device count.
func TestCreateWatchDedupesSameConnectionIdentityAcrossDevices(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	deviceA, _ := s.CreateDevice(ctx, "tokA", api.EnvironmentSandbox)
	deviceB, _ := s.CreateDevice(ctx, "tokB", api.EnvironmentSandbox)

	mk := func(accountID string) api.CreateWatchRequest {
		return api.CreateWatchRequest{
			AccountID: accountID, ImapHost: "203.0.113.10", ImapPort: 993, ImapUseTLS: true,
			ImapUsername: "shared@example.com",
			Auth:         api.WatchAuth{Type: api.WatchAuthPassword, Secret: "same-password"},
			Mailbox:      "INBOX",
		}
	}
	respA, err := s.CreateWatch(ctx, deviceA.DeviceID, mk("account-on-device-a"))
	if err != nil {
		t.Fatal(err)
	}
	respB, err := s.CreateWatch(ctx, deviceB.DeviceID, mk("account-on-device-b"))
	if err != nil {
		t.Fatal(err)
	}
	if respA.WatchID != respB.WatchID {
		t.Fatalf("expected both devices to share one watch, got %q and %q", respA.WatchID, respB.WatchID)
	}

	records, err := s.ListWatches(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 {
		t.Fatalf("expected exactly one underlying watch (one IMAP connection), got %d: %+v", len(records), records)
	}

	subscribers, err := s.WatchSubscribers(ctx, respA.WatchID)
	if err != nil {
		t.Fatal(err)
	}
	if len(subscribers) != 2 {
		t.Fatalf("expected both devices as subscribers, got %+v", subscribers)
	}
	byDevice := map[string]string{}
	for _, sub := range subscribers {
		byDevice[sub.DeviceID] = sub.AccountID
	}
	if byDevice[deviceA.DeviceID] != "account-on-device-a" || byDevice[deviceB.DeviceID] != "account-on-device-b" {
		t.Fatalf("each device should keep its own local accountId, got %+v", byDevice)
	}

	// Deleting device A's registration must not disturb device B's — the
	// watch keeps running for B.
	fullyRemoved, err := s.DeleteWatch(ctx, respA.WatchID, deviceA.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	if fullyRemoved {
		t.Fatal("watch still has a subscriber (device B) and must not be reported as fully removed")
	}
	records, _ = s.ListWatches(ctx)
	if len(records) != 1 {
		t.Fatal("watch should still exist while device B is subscribed")
	}
	subscribers, _ = s.WatchSubscribers(ctx, respA.WatchID)
	if len(subscribers) != 1 || subscribers[0].DeviceID != deviceB.DeviceID {
		t.Fatalf("expected only device B left, got %+v", subscribers)
	}

	// Deleting the last subscriber (device B) does fully remove it.
	fullyRemoved, err = s.DeleteWatch(ctx, respA.WatchID, deviceB.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	if !fullyRemoved {
		t.Fatal("expected the last subscriber's delete to fully remove the watch")
	}
	records, _ = s.ListWatches(ctx)
	if len(records) != 0 {
		t.Fatal("watch should be gone once every subscriber has deleted it")
	}
}

// TestConcurrentCreateWatchForSameIdentityStillProducesOneWatch is Task
// #208's concurrency regression test: CreateWatch's "does a matching watch
// already exist?" check and its insert/update are not atomic by
// themselves, so many devices registering the exact same connection
// identity at (as close as a test can get to) the same instant must still
// converge on exactly one `watch` row — not one each, which would silently
// defeat the entire point of this task. See CreateWatch's own doc comment
// on the transaction it opens for why this is safe.
func TestConcurrentCreateWatchForSameIdentityStillProducesOneWatch(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)

	const deviceCount = 8
	var wg sync.WaitGroup
	watchIDs := make([]string, deviceCount)
	errs := make([]error, deviceCount)
	for i := 0; i < deviceCount; i++ {
		device, err := s.CreateDevice(ctx, fmt.Sprintf("tok%d", i), api.EnvironmentSandbox)
		if err != nil {
			t.Fatal(err)
		}
		wg.Add(1)
		go func(i int, deviceID string) {
			defer wg.Done()
			resp, err := s.CreateWatch(ctx, deviceID, api.CreateWatchRequest{
				AccountID: fmt.Sprintf("account-%d", i),
				ImapHost:  "203.0.113.10", ImapPort: 993, ImapUseTLS: true,
				ImapUsername: "shared@example.com",
				Auth:         api.WatchAuth{Type: api.WatchAuthPassword, Secret: "same-password"},
				Mailbox:      "INBOX",
			})
			watchIDs[i] = resp.WatchID
			errs[i] = err
		}(i, device.DeviceID)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("device %d: %v", i, err)
		}
	}
	for i := 1; i < deviceCount; i++ {
		if watchIDs[i] != watchIDs[0] {
			t.Fatalf("expected every device to converge on the same watch, got %+v", watchIDs)
		}
	}

	records, err := s.ListWatches(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 {
		t.Fatalf("expected exactly one underlying watch despite %d concurrent registrations, got %d: %+v", deviceCount, len(records), records)
	}

	subscribers, err := s.WatchSubscribers(ctx, watchIDs[0])
	if err != nil {
		t.Fatal(err)
	}
	if len(subscribers) != deviceCount {
		t.Fatalf("expected all %d devices as subscribers, got %d: %+v", deviceCount, len(subscribers), subscribers)
	}
}

// TestCreateWatchDoesNotDedupeDifferentAuthType documents the boundary of
// the dedup condition: same connection identity but a DIFFERENT authType
// (password vs oauth for the same host/username/mailbox — not a realistic
// real-world case, but the identity match must not silently ignore it)
// must NOT be merged into one watch.
func TestCreateWatchDoesNotDedupeDifferentAuthType(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	deviceA, _ := s.CreateDevice(ctx, "tokA", api.EnvironmentSandbox)
	deviceB, _ := s.CreateDevice(ctx, "tokB", api.EnvironmentSandbox)

	base := api.CreateWatchRequest{
		ImapHost: "203.0.113.10", ImapPort: 993, ImapUseTLS: true,
		ImapUsername: "shared@example.com", Mailbox: "INBOX",
	}
	passwordReq := base
	passwordReq.AccountID = "account-password"
	passwordReq.Auth = api.WatchAuth{Type: api.WatchAuthPassword, Secret: "pw"}

	provider := api.ProviderGoogle
	oauthReq := base
	oauthReq.AccountID = "account-oauth"
	oauthReq.Auth = api.WatchAuth{Type: api.WatchAuthOAuth, Secret: "refresh-token", Provider: &provider}

	respA, err := s.CreateWatch(ctx, deviceA.DeviceID, passwordReq)
	if err != nil {
		t.Fatal(err)
	}
	respB, err := s.CreateWatch(ctx, deviceB.DeviceID, oauthReq)
	if err != nil {
		t.Fatal(err)
	}
	if respA.WatchID == respB.WatchID {
		t.Fatal("password and oauth watches for the same host/username must not be merged")
	}
	records, err := s.ListWatches(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 2 {
		t.Fatalf("expected two separate watches, got %d", len(records))
	}
}

// TestCreateWatchUpdatesCredentialOnMismatchAndResetsErrorState covers the
// "different devices carry different credentials for the same mailbox"
// case from Task #208's brief: a later registration with a different
// secret for the same connection identity overwrites the stored credential
// (documented "last registration wins" rule — see CreateWatch's doc
// comment) and clears any stopped/error state so the new credential gets a
// clean first attempt.
func TestCreateWatchUpdatesCredentialOnMismatchAndResetsErrorState(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	deviceA, _ := s.CreateDevice(ctx, "tokA", api.EnvironmentSandbox)
	deviceB, _ := s.CreateDevice(ctx, "tokB", api.EnvironmentSandbox)

	mk := func(accountID, secret string) api.CreateWatchRequest {
		return api.CreateWatchRequest{
			AccountID: accountID, ImapHost: "203.0.113.10", ImapPort: 993, ImapUseTLS: true,
			ImapUsername: "shared@example.com",
			Auth:         api.WatchAuth{Type: api.WatchAuthPassword, Secret: secret},
			Mailbox:      "INBOX",
		}
	}
	respA, err := s.CreateWatch(ctx, deviceA.DeviceID, mk("account-a", "old-password"))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.RecordWatchError(ctx, respA.WatchID, api.ErrorKindAuthFailure, true); err != nil {
		t.Fatal(err)
	}
	summaries, _ := s.ListWatchSummaries(ctx, deviceA.DeviceID)
	if len(summaries) != 1 || summaries[0].Status != api.WatchStatusStopped {
		t.Fatalf("expected the watch to be stopped before the credential update, got %+v", summaries)
	}

	respB, err := s.CreateWatch(ctx, deviceB.DeviceID, mk("account-b", "new-password"))
	if err != nil {
		t.Fatal(err)
	}
	if respB.WatchID != respA.WatchID {
		t.Fatal("expected the same watch to be reused despite the differing secret")
	}

	records, err := s.ListWatches(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].Secret != "new-password" {
		t.Fatalf("expected the stored credential to be overwritten with the latest registration's secret, got %+v", records)
	}

	summaries, _ = s.ListWatchSummaries(ctx, deviceA.DeviceID)
	if len(summaries) != 1 || summaries[0].Status != api.WatchStatusActive || summaries[0].LastErrorKind != nil {
		t.Fatalf("expected the credential update to reset stopped/error state, got %+v", summaries)
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

// TestOpensLegacyPerDeviceWatchSchemaAndDropsWatchTable simulates a
// database file created by a pre-Task-#208 relay (one `watch` row per
// device per account — the same shape Task #173's "pre-#173 columns" test
// used to additionally exercise before this rewrite). Task #208 changed
// `watch` from a per-device row to a shared-connection-plus-subscriptions
// design (see dropLegacyPerDeviceWatchTableIfPresent's doc comment) that
// has no meaningful row-by-row migration path, so opening a database this
// old intentionally drops the legacy `watch` table's contents rather than
// trying to preserve them — this test's job is to prove that drop is safe
// (Open succeeds, the unrelated `device` table survives untouched, and the
// store is immediately usable afterward), not that old watches survive.
func TestOpensLegacyPerDeviceWatchSchemaAndDropsWatchTable(t *testing.T) {
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

	// Now open with the real Store — it must not error, and must discard
	// the legacy per-device watch row rather than choke on its old shape.
	s, err := Open(dbPath, c)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	records, err := s.ListWatches(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 0 {
		t.Fatalf("expected the legacy watch row to be dropped, got %+v", records)
	}

	summaries, err := s.ListWatchSummaries(ctx, "dev1")
	if err != nil {
		t.Fatal(err)
	}
	if len(summaries) != 0 {
		t.Fatalf("expected no summaries for the dropped legacy watch, got %+v", summaries)
	}

	// The `device` row itself (a different table, untouched by the drop)
	// must still resolve — only watches are discarded, not devices. The
	// app's WatchReconciler uses this: the device doesn't need
	// re-registering, only its watches (which it recreates automatically
	// via GET /v1/watches returning none for its local accounts).
	deviceID, ok, err := s.DeviceIDForSecret(ctx, "secret1")
	if err != nil {
		t.Fatal(err)
	}
	if !ok || deviceID != "dev1" {
		t.Fatalf("got deviceID=%q ok=%v", deviceID, ok)
	}

	// The store must be immediately usable afterward — a fresh CreateWatch
	// against the same identity the legacy row had must succeed cleanly
	// under the new schema.
	resp, err := s.CreateWatch(ctx, "dev1", api.CreateWatchRequest{
		AccountID: "legacy-account", ImapHost: "legacy.example.com", ImapPort: 993, ImapUseTLS: true,
		ImapUsername: "user@example.com", Auth: api.WatchAuth{Type: api.WatchAuthPassword, Secret: "fresh-password"}, Mailbox: "INBOX",
	})
	if err != nil {
		t.Fatal(err)
	}
	records, err = s.ListWatches(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].Secret != "fresh-password" {
		t.Fatalf("got %+v", records)
	}
	summaries, err = s.ListWatchSummaries(ctx, "dev1")
	if err != nil {
		t.Fatal(err)
	}
	if len(summaries) != 1 || summaries[0].WatchID != resp.WatchID || summaries[0].AccountID != "legacy-account" {
		t.Fatalf("got %+v", summaries)
	}
}

// TestOpensRealSwiftProducedDatabase was originally Task #180's strongest
// compatibility check ("暗号化互換の検証結果 (最重要)" requirement):
// testdata/legacy-swift-relay.sqlite is not a hand-built fixture — it was
// produced by actually running the real Swift relay
// (server/otegami-relay, unmodified) against a fresh RELAY_MASTER_KEY,
// then registering a device via `POST /v1/devices` and creating one
// `.password` and one `.oauth` watch via `POST /v1/watches` over real
// HTTP, exactly as a production deployment would. The master key below is
// a one-off test key generated for this fixture only (`openssl rand
// -base64 32`), never used for anything else — safe to commit.
//
// Task #208 changed `watch` from a per-device row to a shared-connection-
// plus-subscriptions design with no meaningful migration path from the old
// shape (see dropLegacyPerDeviceWatchTableIfPresent's doc comment), so this
// fixture's two legacy watch rows are now intentionally dropped on Open
// rather than preserved. What this test still proves: (1) a real
// Swift-relay-produced database — not just a hand-built fixture — opens
// without error under the new schema, and (2) the `device` row (a
// different table, unaffected by the drop) still authenticates end to end,
// which is the part of "compatibility" that actually matters going
// forward (devices don't need to be re-registered, only their watches).
// The AES-256-GCM decrypt-compatibility this test used to verify via
// `watch.encryptedSecret` is still independently covered by
// internal/cryptox's own TestDecryptsSwiftEncryptedFixture* tests (fixed
// ciphertext produced by real Swift `AES.GCM.seal`, decrypted here) — that
// coverage does not depend on any particular `watch` table shape.
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
	if len(records) != 0 {
		t.Fatalf("expected the legacy per-device watch rows to be dropped, got %+v", records)
	}

	// Confirm a device secret still round-trips end to end: the device row
	// stores only a SHA-256 hash (never the plaintext secret from
	// registration time), so this checks the hash comparison path instead.
	// The `device` table's shape didn't change, so this is untouched by
	// the watch-table drop above.
	deviceID, ok, err := s.DeviceIDForSecret(ctx, "jxkmqQKsmWo3O-BEOa5DfRgBfXalG3WNBshcUuiTH-o")
	if err != nil {
		t.Fatal(err)
	}
	if !ok || deviceID != "ivwEgjYel_znk2CwH7U-4A" {
		t.Fatalf("got deviceID=%q ok=%v", deviceID, ok)
	}
}
