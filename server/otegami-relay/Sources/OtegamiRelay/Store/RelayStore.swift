import Crypto
import Foundation
import NIOCore
import NIOPosix
import OtegamiRelayAPI
import SQLiteNIO

/// The relay's persistence layer: `device` (one row per app install that
/// opted in to push) and `watch` (one row per account being IDLE-watched
/// for that device). Backed by SQLite via SQLiteNIO — see `Package.swift`'s
/// doc comment on that choice over GRDB.
///
/// **Credential handling** (plan §7's privacy design, reflected here):
/// - A device's bearer credential (`deviceSecret`) is returned to the
///   caller exactly once, at `POST /v1/devices` time, and stored here only
///   as a SHA-256 hash — like a password, it can be verified but never
///   recovered.
/// - A watch's IMAP secret (password) genuinely needs to be recoverable
///   (the relay has to present it to the IMAP server on every reconnect),
///   so it's stored `CredentialCrypto`-encrypted rather than hashed.
///   `deleteWatch` removes the row outright, wiping the encrypted
///   credential immediately.
actor RelayStore {
    struct WatchRecord: Sendable, Identifiable {
        var id: String
        var deviceId: String
        var accountId: String
        var imapHost: String
        var imapPort: Int
        var imapUseTLS: Bool
        var imapUsername: String
        var authType: WatchAuth.Kind
        /// Decrypted IMAP secret — never logged, never re-exposed over the
        /// API; only `WatcherPool` reads this, to open its own IMAP
        /// connection.
        var secret: String
        var mailbox: String
        var createdAt: Date
    }

    struct DevicePushTarget: Sendable {
        var apnsToken: String
        var environment: RegisterDeviceRequest.Environment
    }

    enum RelayStoreError: Error, Equatable, CustomStringConvertible {
        case deviceNotFound
        case watchNotFound

        var description: String {
            switch self {
            case .deviceNotFound: "device not found"
            case .watchNotFound: "watch not found"
            }
        }
    }

    private let connection: SQLiteConnection
    private let crypto: CredentialCrypto

    private init(connection: SQLiteConnection, crypto: CredentialCrypto) {
        self.connection = connection
        self.crypto = crypto
    }

    static func open(
        storage: SQLiteConnection.Storage,
        threadPool: NIOThreadPool,
        eventLoop: any EventLoop,
        crypto: CredentialCrypto
    ) async throws -> RelayStore {
        let connection = try await SQLiteConnection.open(
            storage: storage,
            threadPool: threadPool,
            on: eventLoop
        ).get()
        let store = RelayStore(connection: connection, crypto: crypto)
        try await store.migrate()
        return store
    }

    func close() async throws {
        try await connection.close().get()
    }

    private func migrate() async throws {
        _ = try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS device (
                id TEXT PRIMARY KEY,
                secretHash TEXT NOT NULL,
                apnsToken TEXT NOT NULL DEFAULT '',
                environment TEXT NOT NULL DEFAULT 'sandbox',
                createdAt TEXT NOT NULL
            )
            """
        )
        _ = try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS watch (
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
            )
            """
        )
        _ = try await connection.query(
            "CREATE INDEX IF NOT EXISTS watch_deviceId ON watch(deviceId)"
        )
        // Task #173: a relay that's been running since before these
        // columns existed has a `watch` table that `CREATE TABLE IF NOT
        // EXISTS` above leaves untouched — add them the first time this
        // (now-newer) binary runs against that database. Guarded by
        // `PRAGMA table_info` rather than a fixed "schema version" counter
        // because that's all this store has ever used for evolution so
        // far, and a handful of `ADD COLUMN`s doesn't yet justify a
        // heavier migration mechanism.
        try await addWatchColumnsIfMissing()
    }

    private func addWatchColumnsIfMissing() async throws {
        let existing = try await connection.query("PRAGMA table_info(watch)")
        let existingNames = Set(existing.compactMap { $0.column("name")?.string })
        if !existingNames.contains("status") {
            _ = try await connection.query("ALTER TABLE watch ADD COLUMN status TEXT NOT NULL DEFAULT 'active'")
        }
        if !existingNames.contains("lastConnectedAt") {
            _ = try await connection.query("ALTER TABLE watch ADD COLUMN lastConnectedAt TEXT")
        }
        if !existingNames.contains("lastErrorKind") {
            _ = try await connection.query("ALTER TABLE watch ADD COLUMN lastErrorKind TEXT")
        }
        if !existingNames.contains("lastErrorAt") {
            _ = try await connection.query("ALTER TABLE watch ADD COLUMN lastErrorAt TEXT")
        }
    }

    // MARK: - Devices

    func createDevice(
        apnsToken: String,
        environment: RegisterDeviceRequest.Environment
    ) async throws -> RegisterDeviceResponse {
        let id = Self.randomToken()
        let secret = Self.randomToken(byteCount: 32)
        _ = try await connection.query(
            """
            INSERT INTO device (id, secretHash, apnsToken, environment, createdAt)
            VALUES (?, ?, ?, ?, ?)
            """,
            [
                .text(id),
                .text(Self.hash(secret)),
                .text(apnsToken),
                .text(environment.rawValue),
                .text(Self.iso8601.string(from: Date())),
            ]
        )
        return RegisterDeviceResponse(deviceId: id, deviceSecret: secret)
    }

    /// Verifies `secret` is the current bearer credential for `deviceId`.
    func verifyDevice(id: String, secret: String) async throws -> Bool {
        let rows = try await connection.query(
            "SELECT secretHash FROM device WHERE id = ?",
            [.text(id)]
        )
        guard let hash = rows.first?.column("secretHash")?.string else { return false }
        return Self.constantTimeEquals(hash, Self.hash(secret))
    }

    /// Resolves an `Authorization: Bearer <deviceSecret>` value to the
    /// device it belongs to — every device-scoped route
    /// (`updateDeviceToken`, `createWatch`, `deleteWatch`) authenticates
    /// this way rather than taking a device id in the URL, per plan §7
    /// ("POST /v1/watches (Bearer deviceSecret 認証)"). A linear scan over
    /// every device's secret hash: self-hosted deployments are expected to
    /// have a handful of devices at most, so this trades a negligible
    /// amount of CPU for not needing a second, non-secret device
    /// identifier in every request.
    func deviceId(forSecret secret: String) async throws -> String? {
        let rows = try await connection.query("SELECT id, secretHash FROM device")
        let hash = Self.hash(secret)
        for row in rows {
            guard let id = row.column("id")?.string,
                  let storedHash = row.column("secretHash")?.string
            else { continue }
            if Self.constantTimeEquals(storedHash, hash) {
                return id
            }
        }
        return nil
    }

    func updateDeviceToken(
        id: String,
        apnsToken: String,
        environment: RegisterDeviceRequest.Environment
    ) async throws {
        let existing = try await connection.query("SELECT id FROM device WHERE id = ?", [.text(id)])
        guard !existing.isEmpty else { throw RelayStoreError.deviceNotFound }
        _ = try await connection.query(
            "UPDATE device SET apnsToken = ?, environment = ? WHERE id = ?",
            [.text(apnsToken), .text(environment.rawValue), .text(id)]
        )
    }

    func pushTarget(forDeviceId deviceId: String) async throws -> DevicePushTarget? {
        let rows = try await connection.query(
            "SELECT apnsToken, environment FROM device WHERE id = ?",
            [.text(deviceId)]
        )
        guard let row = rows.first,
              let token = row.column("apnsToken")?.string,
              let envRaw = row.column("environment")?.string,
              let environment = RegisterDeviceRequest.Environment(rawValue: envRaw),
              !token.isEmpty
        else { return nil }
        return DevicePushTarget(apnsToken: token, environment: environment)
    }

    // MARK: - Watches

    func createWatch(deviceId: String, request: CreateWatchRequest) async throws -> WatchResponse {
        let id = Self.randomToken()
        let createdAt = Date()
        let encrypted = try crypto.encrypt(request.auth.secret)
        _ = try await connection.query(
            """
            INSERT INTO watch (
                id, deviceId, accountId, imapHost, imapPort, imapUseTLS,
                imapUsername, authType, encryptedSecret, mailbox, createdAt
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(id),
                .text(deviceId),
                .text(request.accountId),
                .text(request.imapHost),
                .integer(request.imapPort),
                .integer(request.imapUseTLS ? 1 : 0),
                .text(request.imapUsername),
                .text(request.auth.type.rawValue),
                .blob(ByteBuffer(data: encrypted)),
                .text(request.mailbox),
                .text(Self.iso8601.string(from: createdAt)),
            ]
        )
        return WatchResponse(
            watchId: id,
            accountId: request.accountId,
            mailbox: request.mailbox,
            createdAt: createdAt
        )
    }

    /// Deletes the watch, but only if it belongs to `deviceId` — a device
    /// can never delete another device's watch, even if it somehow learned
    /// its id. Throws `.watchNotFound` (mapped to 404) if it doesn't exist
    /// or doesn't belong to this device (the two are deliberately
    /// indistinguishable to the caller, to avoid leaking watch existence
    /// across devices).
    func deleteWatch(id: String, deviceId: String) async throws {
        let rows = try await connection.query(
            "SELECT id FROM watch WHERE id = ? AND deviceId = ?",
            [.text(id), .text(deviceId)]
        )
        guard !rows.isEmpty else { throw RelayStoreError.watchNotFound }
        _ = try await connection.query("DELETE FROM watch WHERE id = ?", [.text(id)])
    }

    /// Every watch across every device, credentials decrypted — used only
    /// by `WatcherPool` to (re)build its in-memory set of live IMAP IDLE
    /// connections on startup and on its periodic reconciliation pass.
    func listWatches() async throws -> [WatchRecord] {
        try await watches(whereClause: "", binds: [])
    }

    /// Single-watch lookup, credential decrypted — `WatcherPool`'s
    /// per-watch loop calls this on every reconnect attempt (rather than
    /// caching the record across the loop's lifetime) so a watch deleted
    /// mid-connection is noticed and the loop exits instead of retrying
    /// forever against now-wiped credentials.
    func watch(id: String) async throws -> WatchRecord? {
        try await watches(whereClause: "WHERE id = ?", binds: [.text(id)]).first
    }

    /// `GET /v1/watches`'s backing query — every watch belonging to
    /// `deviceId`, scoped exactly like `deleteWatch` (a device only ever
    /// sees its own watches). Deliberately its own query rather than
    /// filtering `watches(whereClause:binds:)`'s result: that helper always
    /// decrypts `encryptedSecret` (needed by `WatcherPool`, which is its
    /// only other caller), and a listing endpoint that hands the result
    /// straight back over HTTP has no reason to ever hold a plaintext IMAP
    /// credential in memory, let alone risk it leaking into a future
    /// response shape.
    func listWatchSummaries(deviceId: String) async throws -> [WatchSummary] {
        let rows = try await connection.query(
            """
            SELECT id, accountId, imapHost, mailbox, createdAt,
                   status, lastConnectedAt, lastErrorKind, lastErrorAt
            FROM watch
            WHERE deviceId = ?
            ORDER BY createdAt ASC
            """,
            [.text(deviceId)]
        )
        return try rows.map { row in
            guard let id = row.column("id")?.string,
                  let accountId = row.column("accountId")?.string,
                  let imapHost = row.column("imapHost")?.string,
                  let mailbox = row.column("mailbox")?.string,
                  let createdAtRaw = row.column("createdAt")?.string,
                  let createdAt = Self.iso8601.date(from: createdAtRaw)
            else {
                throw RelayStoreError.watchNotFound
            }
            // `status` has a `NOT NULL DEFAULT 'active'` column
            // constraint, but an unrecognized value (shouldn't happen —
            // only this file ever writes it — but a raw DB edit or a
            // future rollback could produce one) falls back to `.active`
            // rather than failing the whole listing.
            let status = row.column("status")?.string.flatMap(WatchSummary.Status.init(rawValue:)) ?? .active
            let lastConnectedAt = row.column("lastConnectedAt")?.string.flatMap(Self.iso8601.date(from:))
            let lastErrorKind = row.column("lastErrorKind")?.string.flatMap(WatchSummary.ErrorKind.init(rawValue:))
            let lastErrorAt = row.column("lastErrorAt")?.string.flatMap(Self.iso8601.date(from:))
            return WatchSummary(
                watchId: id,
                accountId: accountId,
                imapHost: imapHost,
                mailbox: mailbox,
                createdAt: createdAt,
                status: status,
                lastConnectedAt: lastConnectedAt,
                lastErrorKind: lastErrorKind,
                lastErrorAt: lastErrorAt
            )
        }
    }

    // MARK: - Watch status (Task #173)

    /// Called by `WatcherPool` right after a watch's IMAP `LOGIN`/`SELECT`
    /// succeeds — marks it `.active`, records the connection time, and
    /// clears whatever error was previously recorded (a fresh success
    /// supersedes it). A no-op if the watch has since been deleted (the
    /// `WHERE id = ?` simply matches no rows).
    func markWatchConnected(id: String) async throws {
        _ = try await connection.query(
            "UPDATE watch SET status = 'active', lastConnectedAt = ?, lastErrorKind = NULL, lastErrorAt = NULL WHERE id = ?",
            [.text(Self.iso8601.string(from: Date())), .text(id)]
        )
    }

    /// Called by `WatcherPool` on a failed connection/login attempt.
    /// `stopping` marks the watch `.stopped` (currently only reached after
    /// `maxConsecutiveAuthFailures` consecutive `.authFailure`s) — a
    /// non-stopping call just records the error for display while the
    /// loop keeps retrying on its own, matching `WatchSummary.ErrorKind`'s
    /// doc comment on `.connectionError` never stopping the loop by
    /// itself.
    func recordWatchError(id: String, kind: WatchSummary.ErrorKind, stopping: Bool) async throws {
        let now = Self.iso8601.string(from: Date())
        if stopping {
            _ = try await connection.query(
                "UPDATE watch SET status = 'stopped', lastErrorKind = ?, lastErrorAt = ? WHERE id = ?",
                [.text(kind.rawValue), .text(now), .text(id)]
            )
        } else {
            _ = try await connection.query(
                "UPDATE watch SET lastErrorKind = ?, lastErrorAt = ? WHERE id = ?",
                [.text(kind.rawValue), .text(now), .text(id)]
            )
        }
    }

    private func watches(whereClause: String, binds: [SQLiteData]) async throws -> [WatchRecord] {
        let rows = try await connection.query(
            """
            SELECT id, deviceId, accountId, imapHost, imapPort, imapUseTLS,
                   imapUsername, authType, encryptedSecret, mailbox, createdAt
            FROM watch
            \(whereClause)
            """,
            binds
        )
        return try rows.map { row in
            guard let id = row.column("id")?.string,
                  let deviceId = row.column("deviceId")?.string,
                  let accountId = row.column("accountId")?.string,
                  let imapHost = row.column("imapHost")?.string,
                  let imapPort = row.column("imapPort")?.integer,
                  let imapUseTLS = row.column("imapUseTLS")?.integer,
                  let imapUsername = row.column("imapUsername")?.string,
                  let authTypeRaw = row.column("authType")?.string,
                  let authType = WatchAuth.Kind(rawValue: authTypeRaw),
                  let encryptedBuffer = row.column("encryptedSecret")?.blob,
                  let mailbox = row.column("mailbox")?.string,
                  let createdAtRaw = row.column("createdAt")?.string,
                  let createdAt = Self.iso8601.date(from: createdAtRaw)
            else {
                throw RelayStoreError.watchNotFound
            }
            let encryptedData = Data(buffer: encryptedBuffer)
            let secret = try crypto.decrypt(encryptedData)
            return WatchRecord(
                id: id,
                deviceId: deviceId,
                accountId: accountId,
                imapHost: imapHost,
                imapPort: imapPort,
                imapUseTLS: imapUseTLS != 0,
                imapUsername: imapUsername,
                authType: authType,
                secret: secret,
                mailbox: mailbox,
                createdAt: createdAt
            )
        }
    }

    // MARK: - Helpers

    // `ISO8601DateFormatter` isn't `Sendable`, so a shared static instance
    // can't cross actor isolation safely; a fresh one per call is cheap
    // enough at this call rate (device/watch CRUD, not a hot loop).
    private static var iso8601: ISO8601DateFormatter { ISO8601DateFormatter() }

    static func randomToken(byteCount: Int = 16) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        // Base64url, unpadded — safe to embed in a URL path segment
        // (watch/device ids) or an `Authorization: Bearer` header
        // (device secrets) without escaping.
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Avoids a timing side-channel on device-secret comparison (both
    /// inputs are already-hashed, fixed-length hex strings, so a naive
    /// `==` would leak how many leading hex characters match via response
    /// latency).
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var diff: UInt8 = 0
        for index in lhsBytes.indices {
            diff |= lhsBytes[index] ^ rhsBytes[index]
        }
        return diff == 0
    }

    /// Test-only escape hatch: exposes the raw (still AES-GCM-encrypted)
    /// bytes actually persisted for the most recently created watch, so
    /// `RelayStoreTests.credentialsAreEncryptedAtRest` can assert the
    /// plaintext credential never appears in what's on disk — every other
    /// method on this type only ever returns the decrypted secret.
    func rawEncryptedSecretForTesting() async throws -> String? {
        let rows = try await connection.query(
            "SELECT encryptedSecret FROM watch ORDER BY createdAt DESC LIMIT 1"
        )
        guard let blob = rows.first?.column("encryptedSecret")?.blob else { return nil }
        return String(decoding: Data(buffer: blob), as: UTF8.self)
    }
}
