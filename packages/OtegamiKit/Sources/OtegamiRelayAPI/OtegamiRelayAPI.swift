import Foundation

// DTOs shared between the app (`apps/Otegami`) and the push relay server
// (`server/otegami-relay`). Linux-compatible (Foundation only) so the
// server target — which builds and runs on Linux — can depend on this
// package directly instead of hand-duplicating the wire format.
//
// API surface (plan §7):
//   POST   /v1/devices           -> RegisterDeviceRequest / RegisterDeviceResponse
//   PUT    /v1/devices/:id/token -> UpdateDeviceTokenRequest
//   POST   /v1/watches           -> CreateWatchRequest      (Bearer deviceSecret)
//   DELETE /v1/watches/:id       -> (no body; wipes credentials immediately)
//   GET    /v1/watches           -> ListWatchesResponse     (Bearer deviceSecret; this device's watches only)
//   GET    /health               -> plain "ok"
//
// Every request that creates/reads a watch must be authenticated as the
// owning device via `Authorization: Bearer <deviceSecret>` — see
// docs/relay-deployment.md's threat model section for why the secret,
// rather than the device id, is the bearer credential.

/// `POST /v1/devices` request body: registers a new device with the relay.
/// `apnsToken` may be empty at registration time if the app hasn't finished
/// the APNs registration round-trip yet — `PUT /v1/devices/:id/token`
/// updates it once available. `environment` records which APNs environment
/// (sandbox vs production) the token was issued for, since a relay operator
/// self-signs a single server for a single app build and the token format
/// alone doesn't disambiguate.
public struct RegisterDeviceRequest: Codable, Equatable, Sendable {
    public enum Environment: String, Codable, Sendable {
        case sandbox
        case production
    }

    public var apnsToken: String
    public var environment: Environment

    public init(apnsToken: String, environment: Environment) {
        self.apnsToken = apnsToken
        self.environment = environment
    }
}

/// `POST /v1/devices` response: the server-assigned device id and a
/// device secret (bearer credential for every subsequent call scoped to
/// this device). The secret is returned exactly once, at creation time —
/// the server never stores it in recoverable form (see
/// `docs/relay-deployment.md`) — so the app must persist it (Keychain)
/// immediately.
public struct RegisterDeviceResponse: Codable, Equatable, Sendable {
    public var deviceId: String
    public var deviceSecret: String

    public init(deviceId: String, deviceSecret: String) {
        self.deviceId = deviceId
        self.deviceSecret = deviceSecret
    }
}

/// `PUT /v1/devices/:id/token` request body: refreshes the APNs token for
/// an already-registered device (tokens can rotate, e.g. after a
/// reinstall).
public struct UpdateDeviceTokenRequest: Codable, Equatable, Sendable {
    public var apnsToken: String
    public var environment: RegisterDeviceRequest.Environment

    public init(apnsToken: String, environment: RegisterDeviceRequest.Environment) {
        self.apnsToken = apnsToken
        self.environment = environment
    }
}

/// The IMAP credential the relay needs to open its own IDLE connection.
/// `.password` is the only kind implemented in v1 (plan: "LOGIN/XOAUTH2
/// なし可: password のみ v1") — `type` is still explicit so a future
/// `.xoauth2` case can be added without a wire-format break.
public struct WatchAuth: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case password
    }

    public var type: Kind
    /// The IMAP password (or, for a future `.xoauth2` case, a refresh
    /// token). Sent once over TLS at watch-creation time; the server
    /// encrypts it at rest (`CredentialCrypto`) and never echoes it back
    /// in any response.
    public var secret: String

    public init(type: Kind = .password, secret: String) {
        self.type = type
        self.secret = secret
    }
}

/// `POST /v1/watches` request body: asks the relay to open an IMAP IDLE
/// (or STATUS-polling fallback) watch on one mailbox of one account, and
/// to push `deviceId` whenever new mail arrives there.
public struct CreateWatchRequest: Codable, Equatable, Sendable {
    /// Client-chosen identifier for the account being watched (e.g. the
    /// app's local `AccountRecord.id`) — echoed back verbatim in the push
    /// payload so `NotificationService` knows which local account to
    /// re-sync. Never interpreted by the server.
    public var accountId: String
    public var imapHost: String
    public var imapPort: Int
    public var imapUseTLS: Bool
    public var imapUsername: String
    public var auth: WatchAuth
    /// Mailbox path to watch, e.g. `"INBOX"`.
    public var mailbox: String

    public init(
        accountId: String,
        imapHost: String,
        imapPort: Int,
        imapUseTLS: Bool,
        imapUsername: String,
        auth: WatchAuth,
        mailbox: String = "INBOX"
    ) {
        self.accountId = accountId
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapUseTLS = imapUseTLS
        self.imapUsername = imapUsername
        self.auth = auth
        self.mailbox = mailbox
    }
}

/// Response to both `POST /v1/watches` and any future watch-listing
/// endpoint. Never includes the credential.
public struct WatchResponse: Codable, Equatable, Sendable {
    public var watchId: String
    public var accountId: String
    public var mailbox: String
    public var createdAt: Date

    public init(watchId: String, accountId: String, mailbox: String, createdAt: Date) {
        self.watchId = watchId
        self.accountId = accountId
        self.mailbox = mailbox
        self.createdAt = createdAt
    }
}

/// Body of the (minimal, privacy-preserving) push payload the relay sends
/// to APNs, and that `NotificationService` parses back out of
/// `content-available`/`mutable-content` `userInfo`. Deliberately excludes
/// subject/sender/body (plan: "本文/件名を含めない") — the extension fetches
/// those itself via a fresh IMAP round trip.
public struct PushNotificationPayload: Codable, Equatable, Sendable {
    public var accountId: String
    public var uidNext: Int

    public init(accountId: String, uidNext: Int) {
        self.accountId = accountId
        self.uidNext = uidNext
    }
}

/// One entry of `GET /v1/watches`'s response — everything about a watch
/// this device owns *except* its credential (never re-exposed over the
/// API, per `docs/relay-deployment.md`'s threat model). `imapHost` (not
/// present on `WatchResponse`) is included so a future debugging UI could
/// show which server each watch is actually watching. Originally only
/// read `watchId`/`accountId` (M9 follow-up: reconciling the relay's
/// watch list against local accounts on launch/foreground); Task #173
/// added `status`/`lastConnectedAt`/`lastErrorKind`/`lastErrorAt` so the
/// app's push-settings screen can show *which* account's watch actually
/// stopped, instead of a relay operator being the only one who can see
/// that in server logs.
public struct WatchSummary: Codable, Equatable, Sendable {
    /// Whether `WatcherPool`'s per-watch loop (`server/otegami-relay`) is
    /// still actively trying to reach the IMAP server, or gave up.
    public enum Status: String, Codable, Sendable {
        /// Connected at least once and still retrying/idling normally —
        /// includes the case where the *most recent* attempt failed but
        /// the loop hasn't hit `maxConsecutiveAuthFailures` yet (see
        /// `lastErrorKind` to tell those two apart).
        case active
        /// The watch loop gave up permanently (currently: repeated IMAP
        /// login failures — `WatcherPool.maxConsecutiveAuthFailures`) and
        /// will not retry on its own. Only a fresh watch (delete + create
        /// — the app's "re-register" action) starts it again.
        case stopped
    }

    /// Coarse classification of the most recent connection problem, kept
    /// deliberately shallow (never a raw IMAP/network error string — those
    /// can carry hostnames/usernames and this type is displayed straight
    /// to the end user).
    public enum ErrorKind: String, Codable, Sendable {
        /// The IMAP server rejected the stored credential (`LOGIN`
        /// failed). The most common reason a watch ends up `.stopped`.
        case authFailure
        /// A TCP/TLS/protocol-level failure reaching or talking to the
        /// IMAP server — never by itself a reason the loop stops
        /// permanently, it just keeps retrying with backoff.
        case connectionError
    }

    public var watchId: String
    public var accountId: String
    public var imapHost: String
    public var mailbox: String
    public var createdAt: Date
    /// Defaults to `.active` when decoding a response that predates this
    /// field (an app build newer than the relay it's talking to) — the
    /// old relay never tracked this at all, so "active" (no known problem)
    /// is the closest honest fallback.
    public var status: Status
    public var lastConnectedAt: Date?
    public var lastErrorKind: ErrorKind?
    /// Timestamp paired with `lastErrorKind` — `nil` exactly when
    /// `lastErrorKind` is `nil`.
    public var lastErrorAt: Date?

    public init(
        watchId: String,
        accountId: String,
        imapHost: String,
        mailbox: String,
        createdAt: Date,
        status: Status = .active,
        lastConnectedAt: Date? = nil,
        lastErrorKind: ErrorKind? = nil,
        lastErrorAt: Date? = nil
    ) {
        self.watchId = watchId
        self.accountId = accountId
        self.imapHost = imapHost
        self.mailbox = mailbox
        self.createdAt = createdAt
        self.status = status
        self.lastConnectedAt = lastConnectedAt
        self.lastErrorKind = lastErrorKind
        self.lastErrorAt = lastErrorAt
    }

    private enum CodingKeys: String, CodingKey {
        case watchId, accountId, imapHost, mailbox, createdAt
        case status, lastConnectedAt, lastErrorKind, lastErrorAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        watchId = try container.decode(String.self, forKey: .watchId)
        accountId = try container.decode(String.self, forKey: .accountId)
        imapHost = try container.decode(String.self, forKey: .imapHost)
        mailbox = try container.decode(String.self, forKey: .mailbox)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // See the type doc comment: an older relay's response simply
        // won't have these keys, so decode leniently rather than failing
        // the whole list.
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .active
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        lastErrorKind = try container.decodeIfPresent(ErrorKind.self, forKey: .lastErrorKind)
        lastErrorAt = try container.decodeIfPresent(Date.self, forKey: .lastErrorAt)
    }
}

/// `GET /v1/watches` response: every watch the authenticated device owns.
/// The app's `AppEnvironment.reconcilePushWatchesIfNeeded()` treats this as
/// ground truth — a relay watch for an account the app no longer has
/// locally gets `DELETE`d, and a local `.password` account missing from
/// this list gets a fresh watch registered — self-healing the case a
/// prior `DELETE /v1/watches/:id` failed silently (M9's `try?`, no retry)
/// and left a deleted account's watch (and IMAP credential) alive on the
/// relay indefinitely.
public struct ListWatchesResponse: Codable, Equatable, Sendable {
    public var watches: [WatchSummary]

    public init(watches: [WatchSummary]) {
        self.watches = watches
    }
}

/// Uniform error body for every non-2xx relay response.
public struct RelayErrorResponse: Codable, Equatable, Sendable {
    public var error: String
    public var message: String

    public init(error: String, message: String) {
        self.error = error
        self.message = message
    }
}
