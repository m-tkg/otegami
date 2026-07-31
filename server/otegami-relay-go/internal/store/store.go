// Package store is the relay's persistence layer: a `device` table (one
// row per app install that opted in to push) and a `watch` table (one row
// per account being IDLE-watched for that device). Backed by SQLite via
// modernc.org/sqlite (a cgo-free, pure-Go driver) — chosen specifically so
// cross-compiling this relay for arm64 (Raspberry Pi) from an x86_64 CI
// runner needs no C toolchain/QEMU, which is the entire motivation for
// Task #180's Swift-to-Go port (see server/otegami-relay-go/README.md).
//
// Schema and semantics deliberately mirror the retired Swift relay's
// RelayStore exactly: same table/column names and types, same migration-by-
// PRAGMA-table_info approach — an existing production database must open
// and read correctly under this binary with zero migration step (Task
// #180's requirement).
package store

import (
	"context"
	cryptorand "crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"github.com/m-tkg/otegami-relay-go/internal/api"
	"github.com/m-tkg/otegami-relay-go/internal/cryptox"
)

var (
	ErrDeviceNotFound = errors.New("device not found")
	ErrWatchNotFound  = errors.New("watch not found")
)

// WatchRecord mirrors RelayStore.WatchRecord — a fully decrypted, in-memory
// view of one `watch` row.
//
// Task #208: a `watch` row is now the shared IMAP-connection identity
// (host/port/TLS/username/authType/mailbox) — no longer tied to a single
// device or account. Which devices care about this watch, and which local
// accountId each of them should see in its push payload, lives in the
// separate `watch_subscription` table (see WatchSubscriber/WatchSubscribers)
// so N devices watching the same mailbox share exactly one IMAP connection
// instead of one each. See docs/architecture.md's pitfall "i." addendum for
// the motivation (IMAP command volume scales with device count, not account
// count, and Yahoo Japan's rate limiting made that bite in production).
type WatchRecord struct {
	ID           string
	ImapHost     string
	ImapPort     int
	ImapUseTLS   bool
	ImapUsername string
	AuthType     api.WatchAuthKind
	Provider     *api.WatchAuthProvider
	Secret       string // decrypted IMAP password or OAuth refresh token
	Mailbox      string
	CreatedAt    time.Time
	// LastConnectedAt is non-nil iff this watch's credential has
	// authenticated successfully at least once (set by MarkWatchConnected,
	// never cleared by RecordWatchError — see that method's doc comment).
	// Task #187: the watcher pool uses this to tell "this credential has
	// simply always been wrong" apart from "this credential worked before
	// and is now hitting what looks like a transient/lockout-shaped
	// rejection" — only the latter gets the long retry-interval treatment
	// and is spared the permanent give-up (pool.go's
	// authFailureRetryInterval/classifyAuthFailure).
	LastConnectedAt *time.Time
}

// WatchSubscriber is one device's interest in a shared `watch` row —
// mirrors one `watch_subscription` row. AccountID is that device's own
// local accountId (client-chosen, opaque to the relay — see
// api.CreateWatchRequest.AccountID's doc comment), echoed back in the push
// payload sent to DeviceID so the app knows which local account to re-sync.
// Two devices watching the same mailbox can (and typically do) have
// different AccountID values for it, since each app install mints its own
// local ids independently.
type WatchSubscriber struct {
	DeviceID  string
	AccountID string
}

// DevicePushTarget mirrors RelayStore.DevicePushTarget.
type DevicePushTarget struct {
	ApnsToken   string
	Environment api.Environment
}

// Store is the relay's SQLite-backed persistence layer. Safe for
// concurrent use from multiple goroutines (database/sql's *sql.DB pools
// its own connections internally).
type Store struct {
	db     *sql.DB
	crypto *cryptox.CredentialCrypto
}

// Open opens (creating if necessary) the SQLite database at path and runs
// migrations. Pass ":memory:" for an ephemeral in-process database (tests).
func Open(path string, crypto *cryptox.CredentialCrypto) (*Store, error) {
	// `_pragma=foreign_keys(1)` enables the ON DELETE CASCADE the `watch`
	// table declares on its `deviceId` foreign key, matching SQLiteNIO's
	// default behavior on the Swift side (SQLiteNIO enables foreign keys
	// by default). `_pragma=busy_timeout` avoids spurious SQLITE_BUSY
	// errors under the watcher pool's concurrent per-watch status writes.
	dsn := fmt.Sprintf("file:%s?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)", path)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// SQLite only really supports one writer at a time; modernc.org/sqlite
	// (like most Go SQLite drivers) is happiest with a single shared
	// connection serializing writes rather than a pool that can produce
	// concurrent SQLITE_BUSY under load.
	db.SetMaxOpenConns(1)

	s := &Store{db: db, crypto: crypto}
	if err := s.migrate(context.Background()); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) migrate(ctx context.Context) error {
	if err := s.dropLegacyPerDeviceWatchTableIfPresent(ctx); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS device (
			id TEXT PRIMARY KEY,
			secretHash TEXT NOT NULL,
			apnsToken TEXT NOT NULL DEFAULT '',
			environment TEXT NOT NULL DEFAULT 'sandbox',
			createdAt TEXT NOT NULL
		)`,
		// Task #208: `watch` is now the shared IMAP-connection identity —
		// one row per distinct (imapHost, imapPort, imapUseTLS,
		// imapUsername, authType, authProvider, mailbox), no longer one row
		// per device. Which devices are subscribed, and each one's own
		// local accountId, lives in `watch_subscription` below.
		`CREATE TABLE IF NOT EXISTS watch (
			id TEXT PRIMARY KEY,
			imapHost TEXT NOT NULL,
			imapPort INTEGER NOT NULL,
			imapUseTLS INTEGER NOT NULL,
			imapUsername TEXT NOT NULL,
			authType TEXT NOT NULL,
			authProvider TEXT,
			encryptedSecret BLOB NOT NULL,
			mailbox TEXT NOT NULL,
			createdAt TEXT NOT NULL,
			status TEXT NOT NULL DEFAULT 'active',
			lastConnectedAt TEXT,
			lastErrorKind TEXT,
			lastErrorAt TEXT
		)`,
		`CREATE INDEX IF NOT EXISTS watch_identity ON watch(imapHost, imapPort, imapUseTLS, imapUsername, authType, mailbox)`,
		// deviceId/accountId are NOT unique together: re-registering the
		// same device for the same watch (CreateWatch called again before
		// a matching DeleteWatch) upserts the existing row rather than
		// erroring — see CreateWatch's doc comment.
		`CREATE TABLE IF NOT EXISTS watch_subscription (
			id TEXT PRIMARY KEY,
			watchId TEXT NOT NULL REFERENCES watch(id) ON DELETE CASCADE,
			deviceId TEXT NOT NULL REFERENCES device(id) ON DELETE CASCADE,
			accountId TEXT NOT NULL,
			createdAt TEXT NOT NULL,
			UNIQUE(watchId, deviceId)
		)`,
		`CREATE INDEX IF NOT EXISTS watch_subscription_deviceId ON watch_subscription(deviceId)`,
		`CREATE INDEX IF NOT EXISTS watch_subscription_watchId ON watch_subscription(watchId)`,
	}
	for _, stmt := range stmts {
		if _, err := s.db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("migrate: %w", err)
		}
	}
	return s.addWatchColumnsIfMissing(ctx)
}

// dropLegacyPerDeviceWatchTableIfPresent (Task #208): a `watch` table from
// before this task had `deviceId`/`accountId` columns directly on it (one
// row per device per account). That shape is structurally incompatible with
// the shared-connection-plus-subscriptions design below — there is no
// meaningful per-row migration that doesn't also require deciding, for
// credentials that may differ across the legacy per-device rows, which one
// survives (see CreateWatch's doc comment for how a *live* registration
// resolves that). Chosen instead, per this task's explicit brief for a
// personal/test deployment that can re-register every device: drop the
// legacy table outright and let it repopulate itself. The app's
// WatchReconciler already treats GET /v1/watches as ground truth and
// self-heals by re-registering any local account missing from that list on
// its next launch/foreground (packages/OtegamiKit/Sources/PushRelayClient/
// WatchReconciler.swift) — no manual re-registration step is required, only
// a brief gap in push delivery until that next reconcile runs. The `device`
// table (and its rows' deviceSecret-based auth) is untouched, so no device
// needs to be re-registered, only its watches.
func (s *Store) dropLegacyPerDeviceWatchTableIfPresent(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(watch)`)
	if err != nil {
		return err
	}
	hasLegacyDeviceIDColumn := false
	for rows.Next() {
		var cid int
		var name, colType string
		var notNull int
		var dflt sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &colType, &notNull, &dflt, &pk); err != nil {
			rows.Close()
			return err
		}
		if name == "deviceId" {
			hasLegacyDeviceIDColumn = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	rows.Close()
	if !hasLegacyDeviceIDColumn {
		// Either no `watch` table exists yet (PRAGMA table_info on a
		// missing table returns zero rows, not an error), or it's already
		// the new shape from a prior run of this same binary.
		return nil
	}
	_, err = s.db.ExecContext(ctx, `DROP TABLE watch`)
	return err
}

// addWatchColumnsIfMissing mirrors RelayStore.addWatchColumnsIfMissing
// (Task #173/#175): a relay database created before these columns existed
// has a `watch` table `CREATE TABLE IF NOT EXISTS` above leaves untouched —
// add them the first time this binary runs against that database.
func (s *Store) addWatchColumnsIfMissing(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(watch)`)
	if err != nil {
		return err
	}
	existing := map[string]bool{}
	for rows.Next() {
		var cid int
		var name, colType string
		var notNull int
		var dflt sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &colType, &notNull, &dflt, &pk); err != nil {
			rows.Close()
			return err
		}
		existing[name] = true
	}
	if err := rows.Err(); err != nil {
		return err
	}
	rows.Close()

	additions := []struct {
		name string
		ddl  string
	}{
		{"status", `ALTER TABLE watch ADD COLUMN status TEXT NOT NULL DEFAULT 'active'`},
		{"lastConnectedAt", `ALTER TABLE watch ADD COLUMN lastConnectedAt TEXT`},
		{"lastErrorKind", `ALTER TABLE watch ADD COLUMN lastErrorKind TEXT`},
		{"lastErrorAt", `ALTER TABLE watch ADD COLUMN lastErrorAt TEXT`},
		{"authProvider", `ALTER TABLE watch ADD COLUMN authProvider TEXT`},
	}
	for _, addition := range additions {
		if !existing[addition.name] {
			if _, err := s.db.ExecContext(ctx, addition.ddl); err != nil {
				return fmt.Errorf("migrate: add column %s: %w", addition.name, err)
			}
		}
	}
	return nil
}

// --- Time helpers: RelayStore stores timestamps as ISO8601 text
// (`ISO8601DateFormatter().string(from:)`/`.date(from:)`), same format as
// the HTTP API's wire format (see api.WireTime's doc comment).

func formatTime(t time.Time) string {
	return t.UTC().Format(time.RFC3339)
}

func parseTime(s string) (time.Time, bool) {
	if s == "" {
		return time.Time{}, false
	}
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t.UTC(), true
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.UTC(), true
	}
	return time.Time{}, false
}

// --- Random tokens / hashing (mirrors RelayStore's helpers) ---

// HashSecret mirrors RelayStore.hash(_:) — SHA-256 hex digest.
func HashSecret(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

// ConstantTimeEquals avoids a timing side-channel on device-secret
// comparison, mirroring RelayStore.constantTimeEquals.
func ConstantTimeEquals(lhs, rhs string) bool {
	if len(lhs) != len(rhs) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(lhs), []byte(rhs)) == 1
}

// RandomToken mirrors RelayStore.randomToken(byteCount:) — base64url,
// unpadded, safe to embed in a URL path segment or Authorization header
// without escaping.
func RandomToken(byteCount int) (string, error) {
	buf := make([]byte, byteCount)
	if _, err := cryptorand.Read(buf); err != nil {
		return "", err
	}
	encoded := base64.StdEncoding.EncodeToString(buf)
	encoded = strings.NewReplacer("+", "-", "/", "_", "=", "").Replace(encoded)
	return encoded, nil
}

// --- Devices ---

// CreateDevice mirrors RelayStore.createDevice(apnsToken:environment:).
func (s *Store) CreateDevice(ctx context.Context, apnsToken string, environment api.Environment) (api.RegisterDeviceResponse, error) {
	id, err := RandomToken(16)
	if err != nil {
		return api.RegisterDeviceResponse{}, err
	}
	secret, err := RandomToken(32)
	if err != nil {
		return api.RegisterDeviceResponse{}, err
	}
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO device (id, secretHash, apnsToken, environment, createdAt) VALUES (?, ?, ?, ?, ?)`,
		id, HashSecret(secret), apnsToken, string(environment), formatTime(time.Now()),
	)
	if err != nil {
		return api.RegisterDeviceResponse{}, err
	}
	return api.RegisterDeviceResponse{DeviceID: id, DeviceSecret: secret}, nil
}

// DeviceIDForSecret resolves an `Authorization: Bearer <deviceSecret>`
// value to the device it belongs to, mirroring
// RelayStore.deviceId(forSecret:). Returns ("", false) if no device
// matches.
func (s *Store) DeviceIDForSecret(ctx context.Context, secret string) (string, bool, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, secretHash FROM device`)
	if err != nil {
		return "", false, err
	}
	defer rows.Close()
	hash := HashSecret(secret)
	for rows.Next() {
		var id, storedHash string
		if err := rows.Scan(&id, &storedHash); err != nil {
			return "", false, err
		}
		if ConstantTimeEquals(storedHash, hash) {
			return id, true, nil
		}
	}
	return "", false, rows.Err()
}

// UpdateDeviceToken mirrors RelayStore.updateDeviceToken.
func (s *Store) UpdateDeviceToken(ctx context.Context, id, apnsToken string, environment api.Environment) error {
	var exists string
	err := s.db.QueryRowContext(ctx, `SELECT id FROM device WHERE id = ?`, id).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrDeviceNotFound
	}
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `UPDATE device SET apnsToken = ?, environment = ? WHERE id = ?`, apnsToken, string(environment), id)
	return err
}

// PushTarget mirrors RelayStore.pushTarget(forDeviceId:).
func (s *Store) PushTarget(ctx context.Context, deviceID string) (*DevicePushTarget, error) {
	var token, envRaw string
	err := s.db.QueryRowContext(ctx, `SELECT apnsToken, environment FROM device WHERE id = ?`, deviceID).Scan(&token, &envRaw)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if token == "" {
		return nil, nil
	}
	env := api.Environment(envRaw)
	if env != api.EnvironmentSandbox && env != api.EnvironmentProduction {
		return nil, nil
	}
	return &DevicePushTarget{ApnsToken: token, Environment: env}, nil
}

// --- Watches ---

// dbtx is the subset of *sql.DB / *sql.Tx that findMatchingWatch and
// CreateWatch's own statements need — lets the same code run either
// directly against the pool or against one transaction. Necessary here
// (Task #208) because CreateWatch is check-then-act ("does a watch with
// this identity already exist?" followed by an INSERT or UPDATE) and two
// devices registering the same identity at nearly the same moment must not
// race into creating two separate watch rows for it — exactly the
// duplication this whole feature exists to eliminate.
type dbtx interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

// findMatchingWatch (Task #208) looks for an existing `watch` row with the
// same connection identity as req — same server, same credential kind, same
// mailbox — regardless of which device(s) already subscribe to it. Returns
// found == false if no such row exists yet.
func (s *Store) findMatchingWatch(ctx context.Context, tx dbtx, req api.CreateWatchRequest) (id string, decryptedSecret string, found bool, err error) {
	rows, err := tx.QueryContext(ctx,
		`SELECT id, authProvider, encryptedSecret FROM watch
		WHERE imapHost = ? AND imapPort = ? AND imapUseTLS = ? AND imapUsername = ?
			AND authType = ? AND mailbox = ?`,
		req.ImapHost, req.ImapPort, boolToInt(req.ImapUseTLS), req.ImapUsername,
		string(req.Auth.Type), req.Mailbox,
	)
	if err != nil {
		return "", "", false, err
	}
	defer rows.Close()
	for rows.Next() {
		var rowID string
		var providerRaw sql.NullString
		var encryptedSecret []byte
		if err := rows.Scan(&rowID, &providerRaw, &encryptedSecret); err != nil {
			return "", "", false, err
		}
		// authProvider is part of the identity too (an .oauth watch for the
		// same mailbox under a different provider is not the same
		// connection) — compared in Go rather than SQL to sidestep NULL
		// comparison semantics for the common .password (provider == nil)
		// case.
		rowProvider := ""
		if providerRaw.Valid {
			rowProvider = providerRaw.String
		}
		reqProvider := ""
		if req.Auth.Provider != nil {
			reqProvider = string(*req.Auth.Provider)
		}
		if rowProvider != reqProvider {
			continue
		}
		secret, err := s.crypto.Decrypt(encryptedSecret)
		if err != nil {
			return "", "", false, err
		}
		return rowID, secret, true, nil
	}
	if err := rows.Err(); err != nil {
		return "", "", false, err
	}
	return "", "", false, nil
}

// CreateWatch mirrors RelayStore.createWatch(deviceId:request:), extended
// by Task #208 to deduplicate the underlying IMAP connection across
// devices: if a `watch` row already exists for the exact same
// (imapHost, imapPort, imapUseTLS, imapUsername, authType, authProvider,
// mailbox) identity, this call reuses it — adding (or updating) only a
// `watch_subscription` row for deviceID — instead of opening a second IMAP
// connection to the same mailbox.
//
// Credential handling when reusing an existing watch: different devices
// registering "the same account" may not always carry byte-identical
// credentials (e.g. an IMAP app-password rotated on one device but not
// re-entered on another yet, or two independently-obtained OAuth refresh
// tokens for the same mailbox). This call compares the decrypted secret and,
// if it differs from what's stored, overwrites the stored credential with
// this (the most recently registering device's) secret and resets the
// watch's error/backoff state to give the new credential a clean first
// attempt — mirroring what already happens when a single device
// deletes-then-recreates its own watch after a password change. This is a
// deliberate "last registration wins" rule, not a merge: the previous
// credential is simply discarded. It biases toward whichever device
// registered most recently being right, which holds in the ordinary case
// (a credential rotation reaching every device eventually) and does not
// silently accept a *wrong* credential over a *working* one for longer than
// one connection attempt — see connectAndWatch's auth-failure handling
// (pool.go) for what happens if it guessed wrong.
func (s *Store) CreateWatch(ctx context.Context, deviceID string, req api.CreateWatchRequest) (api.WatchResponse, error) {
	// The find-then-insert-or-update below must run as one atomic unit —
	// see dbtx's doc comment. Store.Open sets SetMaxOpenConns(1), so
	// *sql.DB.BeginTx checks out the pool's one and only connection for the
	// duration of the transaction: any other CreateWatch call (from another
	// device, another goroutine) blocks trying to get a connection of its
	// own until this one commits or rolls back, which is exactly the
	// serialization needed here.
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return api.WatchResponse{}, err
	}
	defer func() { _ = tx.Rollback() }() // no-op once Commit has succeeded

	watchID, existingSecret, found, err := s.findMatchingWatch(ctx, tx, req)
	if err != nil {
		return api.WatchResponse{}, err
	}
	if !found {
		watchID, err = RandomToken(16)
		if err != nil {
			return api.WatchResponse{}, err
		}
		encrypted, err := s.crypto.Encrypt(req.Auth.Secret)
		if err != nil {
			return api.WatchResponse{}, err
		}
		var providerValue any
		if req.Auth.Provider != nil {
			providerValue = string(*req.Auth.Provider)
		}
		_, err = tx.ExecContext(ctx,
			`INSERT INTO watch (
				id, imapHost, imapPort, imapUseTLS,
				imapUsername, authType, encryptedSecret, mailbox, createdAt,
				authProvider
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			watchID, req.ImapHost, req.ImapPort, boolToInt(req.ImapUseTLS),
			req.ImapUsername, string(req.Auth.Type), encrypted, req.Mailbox, formatTime(time.Now()),
			providerValue,
		)
		if err != nil {
			return api.WatchResponse{}, err
		}
	} else if existingSecret != req.Auth.Secret {
		encrypted, err := s.crypto.Encrypt(req.Auth.Secret)
		if err != nil {
			return api.WatchResponse{}, err
		}
		// A fresh credential deserves a fresh chance — clear any stopped/
		// error state left by the old (possibly now-wrong) one, same as a
		// brand-new watch starts clean. The watcher pool re-reads the
		// record on its next loop iteration (store.Watch), so a live watch
		// picks up the new credential without needing a restart.
		_, err = tx.ExecContext(ctx,
			`UPDATE watch SET encryptedSecret = ?, status = 'active', lastErrorKind = NULL, lastErrorAt = NULL WHERE id = ?`,
			encrypted, watchID,
		)
		if err != nil {
			return api.WatchResponse{}, err
		}
	}

	subCreatedAt := time.Now()
	subID, err := RandomToken(16)
	if err != nil {
		return api.WatchResponse{}, err
	}
	_, err = tx.ExecContext(ctx,
		`INSERT INTO watch_subscription (id, watchId, deviceId, accountId, createdAt)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(watchId, deviceId) DO UPDATE SET accountId = excluded.accountId, createdAt = excluded.createdAt`,
		subID, watchID, deviceID, req.AccountID, formatTime(subCreatedAt),
	)
	if err != nil {
		return api.WatchResponse{}, err
	}

	if err := tx.Commit(); err != nil {
		return api.WatchResponse{}, err
	}

	return api.WatchResponse{
		WatchID:   watchID,
		AccountID: req.AccountID,
		Mailbox:   req.Mailbox,
		CreatedAt: api.NewWireTime(subCreatedAt),
	}, nil
}

// DeleteWatch mirrors RelayStore.deleteWatch(id:deviceId:) — only removes
// deviceID's own interest in the watch. Task #208: since a `watch` row can
// now be shared by several devices, this only deletes the underlying watch
// (and stops it for good) once its *last* subscribing device deletes it;
// otherwise it just drops this device's `watch_subscription` row and the
// watch keeps running for whoever else still subscribes to it.
// watchFullyRemoved tells the caller (the HTTP route) whether to also call
// watcherPool.RemoveWatch — never left running with no subscribers.
func (s *Store) DeleteWatch(ctx context.Context, id, deviceID string) (watchFullyRemoved bool, err error) {
	var subID string
	err = s.db.QueryRowContext(ctx, `SELECT id FROM watch_subscription WHERE watchId = ? AND deviceId = ?`, id, deviceID).Scan(&subID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, ErrWatchNotFound
	}
	if err != nil {
		return false, err
	}
	if _, err := s.db.ExecContext(ctx, `DELETE FROM watch_subscription WHERE id = ?`, subID); err != nil {
		return false, err
	}
	var remaining int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM watch_subscription WHERE watchId = ?`, id).Scan(&remaining); err != nil {
		return false, err
	}
	if remaining > 0 {
		return false, nil
	}
	if _, err := s.db.ExecContext(ctx, `DELETE FROM watch WHERE id = ?`, id); err != nil {
		return false, err
	}
	return true, nil
}

// WatchSubscribers mirrors the `watch_subscription` rows for one watch —
// used by the watcher pool's fire() (Task #208) to push every subscribing
// device, each with its own locally-meaningful accountId, when one shared
// IMAP connection sees new mail.
func (s *Store) WatchSubscribers(ctx context.Context, watchID string) ([]WatchSubscriber, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT deviceId, accountId FROM watch_subscription WHERE watchId = ?`, watchID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []WatchSubscriber
	for rows.Next() {
		var sub WatchSubscriber
		if err := rows.Scan(&sub.DeviceID, &sub.AccountID); err != nil {
			return nil, err
		}
		out = append(out, sub)
	}
	return out, rows.Err()
}

const watchColumns = `id, imapHost, imapPort, imapUseTLS,
	imapUsername, authType, encryptedSecret, mailbox, createdAt, authProvider,
	lastConnectedAt`

// ListWatches mirrors RelayStore.listWatches() — every watch across every
// device, credentials decrypted.
func (s *Store) ListWatches(ctx context.Context) ([]WatchRecord, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT `+watchColumns+` FROM watch`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return s.scanWatchRecords(rows)
}

// Watch mirrors RelayStore.watch(id:) — single-watch lookup, credential
// decrypted. Returns (nil, nil) if not found.
func (s *Store) Watch(ctx context.Context, id string) (*WatchRecord, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT `+watchColumns+` FROM watch WHERE id = ?`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	records, err := s.scanWatchRecords(rows)
	if err != nil {
		return nil, err
	}
	if len(records) == 0 {
		return nil, nil
	}
	return &records[0], nil
}

func (s *Store) scanWatchRecords(rows *sql.Rows) ([]WatchRecord, error) {
	var out []WatchRecord
	for rows.Next() {
		var (
			id, imapHost, imapUsername, authTypeRaw, mailbox, createdAtRaw string
			imapPort, imapUseTLS                                          int
			encryptedSecret                                               []byte
			authProvider                                                  sql.NullString
			lastConnectedAtRaw                                            sql.NullString
		)
		if err := rows.Scan(
			&id, &imapHost, &imapPort, &imapUseTLS,
			&imapUsername, &authTypeRaw, &encryptedSecret, &mailbox, &createdAtRaw, &authProvider,
			&lastConnectedAtRaw,
		); err != nil {
			return nil, err
		}
		createdAt, ok := parseTime(createdAtRaw)
		if !ok {
			return nil, ErrWatchNotFound
		}
		secret, err := s.crypto.Decrypt(encryptedSecret)
		if err != nil {
			return nil, err
		}
		var provider *api.WatchAuthProvider
		if authProvider.Valid {
			p := api.WatchAuthProvider(authProvider.String)
			if p == api.ProviderGoogle || p == api.ProviderMicrosoft {
				provider = &p
			}
		}
		var lastConnectedAt *time.Time
		if lastConnectedAtRaw.Valid {
			if t, ok := parseTime(lastConnectedAtRaw.String); ok {
				lastConnectedAt = &t
			}
		}
		out = append(out, WatchRecord{
			ID:              id,
			ImapHost:        imapHost,
			ImapPort:        imapPort,
			ImapUseTLS:      imapUseTLS != 0,
			ImapUsername:    imapUsername,
			AuthType:        api.WatchAuthKind(authTypeRaw),
			Provider:        provider,
			Secret:          secret,
			Mailbox:         mailbox,
			CreatedAt:       createdAt,
			LastConnectedAt: lastConnectedAt,
		})
	}
	return out, rows.Err()
}

// ListWatchSummaries mirrors RelayStore.listWatchSummaries(deviceId:) —
// GET /v1/watches's backing query. Never decrypts the credential. Task
// #208: joins through `watch_subscription` since `watch` itself no longer
// carries a deviceId/accountId — accountId and createdAt (the meaning of
// "when did I register this" from this device's own point of view) both
// come from the subscription row; everything else (connection identity,
// status, error info) is shared across every subscriber and comes from the
// `watch` row.
func (s *Store) ListWatchSummaries(ctx context.Context, deviceID string) ([]api.WatchSummary, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT w.id, s.accountId, w.imapHost, w.mailbox, s.createdAt,
			w.status, w.lastConnectedAt, w.lastErrorKind, w.lastErrorAt
		FROM watch_subscription s
		JOIN watch w ON w.id = s.watchId
		WHERE s.deviceId = ?
		ORDER BY s.createdAt ASC`,
		deviceID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []api.WatchSummary
	for rows.Next() {
		var (
			id, accountID, imapHost, mailbox, createdAtRaw string
			statusRaw, lastErrorKindRaw                    sql.NullString
			lastConnectedAtRaw, lastErrorAtRaw             sql.NullString
		)
		if err := rows.Scan(&id, &accountID, &imapHost, &mailbox, &createdAtRaw,
			&statusRaw, &lastConnectedAtRaw, &lastErrorKindRaw, &lastErrorAtRaw); err != nil {
			return nil, err
		}
		createdAt, ok := parseTime(createdAtRaw)
		if !ok {
			return nil, ErrWatchNotFound
		}
		status := api.WatchStatusActive
		if statusRaw.Valid && (api.WatchStatus(statusRaw.String) == api.WatchStatusActive || api.WatchStatus(statusRaw.String) == api.WatchStatusStopped) {
			status = api.WatchStatus(statusRaw.String)
		}
		summary := api.WatchSummary{
			WatchID:   id,
			AccountID: accountID,
			ImapHost:  imapHost,
			Mailbox:   mailbox,
			CreatedAt: api.NewWireTime(createdAt),
			Status:    status,
		}
		if lastConnectedAtRaw.Valid {
			if t, ok := parseTime(lastConnectedAtRaw.String); ok {
				wt := api.NewWireTime(t)
				summary.LastConnectedAt = &wt
			}
		}
		if lastErrorKindRaw.Valid {
			kind := api.WatchErrorKind(lastErrorKindRaw.String)
			if kind == api.ErrorKindAuthFailure || kind == api.ErrorKindConnectionError || kind == api.ErrorKindOAuthTokenExpired {
				summary.LastErrorKind = &kind
			}
		}
		if lastErrorAtRaw.Valid {
			if t, ok := parseTime(lastErrorAtRaw.String); ok {
				wt := api.NewWireTime(t)
				summary.LastErrorAt = &wt
			}
		}
		out = append(out, summary)
	}
	if out == nil {
		out = []api.WatchSummary{}
	}
	return out, rows.Err()
}

// MarkWatchConnected mirrors RelayStore.markWatchConnected(id:) — Task #173.
func (s *Store) MarkWatchConnected(ctx context.Context, id string) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE watch SET status = 'active', lastConnectedAt = ?, lastErrorKind = NULL, lastErrorAt = NULL WHERE id = ?`,
		formatTime(time.Now()), id,
	)
	return err
}

// RecordWatchError mirrors RelayStore.recordWatchError(id:kind:stopping:) —
// Task #173.
func (s *Store) RecordWatchError(ctx context.Context, id string, kind api.WatchErrorKind, stopping bool) error {
	now := formatTime(time.Now())
	if stopping {
		_, err := s.db.ExecContext(ctx,
			`UPDATE watch SET status = 'stopped', lastErrorKind = ?, lastErrorAt = ? WHERE id = ?`,
			string(kind), now, id,
		)
		return err
	}
	_, err := s.db.ExecContext(ctx,
		`UPDATE watch SET lastErrorKind = ?, lastErrorAt = ? WHERE id = ?`,
		string(kind), now, id,
	)
	return err
}

// RawEncryptedSecretForTesting mirrors
// RelayStore.rawEncryptedSecretForTesting() — test-only escape hatch
// exposing the raw (still AES-GCM-encrypted) bytes for the most recently
// created watch.
func (s *Store) RawEncryptedSecretForTesting(ctx context.Context) (string, bool, error) {
	var blob []byte
	err := s.db.QueryRowContext(ctx, `SELECT encryptedSecret FROM watch ORDER BY createdAt DESC LIMIT 1`).Scan(&blob)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return string(blob), true, nil
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
