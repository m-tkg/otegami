// Package store is the relay's persistence layer: a `device` table (one
// row per app install that opted in to push) and a `watch` table (one row
// per account being IDLE-watched for that device). Backed by SQLite via
// modernc.org/sqlite (a cgo-free, pure-Go driver) — chosen specifically so
// cross-compiling this relay for arm64 (Raspberry Pi) from an x86_64 CI
// runner needs no C toolchain/QEMU, which is the entire motivation for
// Task #180's Swift-to-Go port (see server/otegami-relay-go/README.md).
//
// Schema and semantics deliberately mirror the Swift relay's RelayStore
// (server/otegami-relay/Sources/OtegamiRelay/Store/RelayStore.swift)
// exactly: same table/column names and types, same migration-by-
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
type WatchRecord struct {
	ID           string
	DeviceID     string
	AccountID    string
	ImapHost     string
	ImapPort     int
	ImapUseTLS   bool
	ImapUsername string
	AuthType     api.WatchAuthKind
	Provider     *api.WatchAuthProvider
	Secret       string // decrypted IMAP password or OAuth refresh token
	Mailbox      string
	CreatedAt    time.Time
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
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS device (
			id TEXT PRIMARY KEY,
			secretHash TEXT NOT NULL,
			apnsToken TEXT NOT NULL DEFAULT '',
			environment TEXT NOT NULL DEFAULT 'sandbox',
			createdAt TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS watch (
			id TEXT PRIMARY KEY,
			deviceId TEXT NOT NULL REFERENCES device(id) ON DELETE CASCADE,
			accountId TEXT NOT NULL,
			imapHost TEXT NOT NULL,
			imapPort INTEGER NOT NULL,
			imapUseTLS INTEGER NOT NULL,
			imapUsername TEXT NOT NULL,
			authType TEXT NOT NULL,
			encryptedSecret BLOB NOT NULL,
			mailbox TEXT NOT NULL,
			createdAt TEXT NOT NULL,
			status TEXT NOT NULL DEFAULT 'active',
			lastConnectedAt TEXT,
			lastErrorKind TEXT,
			lastErrorAt TEXT
		)`,
		`CREATE INDEX IF NOT EXISTS watch_deviceId ON watch(deviceId)`,
	}
	for _, stmt := range stmts {
		if _, err := s.db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("migrate: %w", err)
		}
	}
	return s.addWatchColumnsIfMissing(ctx)
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

// CreateWatch mirrors RelayStore.createWatch(deviceId:request:).
func (s *Store) CreateWatch(ctx context.Context, deviceID string, req api.CreateWatchRequest) (api.WatchResponse, error) {
	id, err := RandomToken(16)
	if err != nil {
		return api.WatchResponse{}, err
	}
	createdAt := time.Now()
	encrypted, err := s.crypto.Encrypt(req.Auth.Secret)
	if err != nil {
		return api.WatchResponse{}, err
	}
	var providerValue any
	if req.Auth.Provider != nil {
		providerValue = string(*req.Auth.Provider)
	}
	_, err = s.db.ExecContext(ctx,
		`INSERT INTO watch (
			id, deviceId, accountId, imapHost, imapPort, imapUseTLS,
			imapUsername, authType, encryptedSecret, mailbox, createdAt,
			authProvider
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, deviceID, req.AccountID, req.ImapHost, req.ImapPort, boolToInt(req.ImapUseTLS),
		req.ImapUsername, string(req.Auth.Type), encrypted, req.Mailbox, formatTime(createdAt),
		providerValue,
	)
	if err != nil {
		return api.WatchResponse{}, err
	}
	return api.WatchResponse{
		WatchID:   id,
		AccountID: req.AccountID,
		Mailbox:   req.Mailbox,
		CreatedAt: api.NewWireTime(createdAt),
	}, nil
}

// DeleteWatch mirrors RelayStore.deleteWatch(id:deviceId:) — only deletes
// if the watch belongs to deviceID.
func (s *Store) DeleteWatch(ctx context.Context, id, deviceID string) error {
	var exists string
	err := s.db.QueryRowContext(ctx, `SELECT id FROM watch WHERE id = ? AND deviceId = ?`, id, deviceID).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrWatchNotFound
	}
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `DELETE FROM watch WHERE id = ?`, id)
	return err
}

const watchColumns = `id, deviceId, accountId, imapHost, imapPort, imapUseTLS,
	imapUsername, authType, encryptedSecret, mailbox, createdAt, authProvider`

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
			id, deviceID, accountID, imapHost, imapUsername, authTypeRaw, mailbox, createdAtRaw string
			imapPort, imapUseTLS                                                                int
			encryptedSecret                                                                     []byte
			authProvider                                                                        sql.NullString
		)
		if err := rows.Scan(
			&id, &deviceID, &accountID, &imapHost, &imapPort, &imapUseTLS,
			&imapUsername, &authTypeRaw, &encryptedSecret, &mailbox, &createdAtRaw, &authProvider,
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
		out = append(out, WatchRecord{
			ID:           id,
			DeviceID:     deviceID,
			AccountID:    accountID,
			ImapHost:     imapHost,
			ImapPort:     imapPort,
			ImapUseTLS:   imapUseTLS != 0,
			ImapUsername: imapUsername,
			AuthType:     api.WatchAuthKind(authTypeRaw),
			Provider:     provider,
			Secret:       secret,
			Mailbox:      mailbox,
			CreatedAt:    createdAt,
		})
	}
	return out, rows.Err()
}

// ListWatchSummaries mirrors RelayStore.listWatchSummaries(deviceId:) —
// GET /v1/watches's backing query. Never decrypts the credential.
func (s *Store) ListWatchSummaries(ctx context.Context, deviceID string) ([]api.WatchSummary, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, accountId, imapHost, mailbox, createdAt,
			status, lastConnectedAt, lastErrorKind, lastErrorAt
		FROM watch
		WHERE deviceId = ?
		ORDER BY createdAt ASC`,
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
