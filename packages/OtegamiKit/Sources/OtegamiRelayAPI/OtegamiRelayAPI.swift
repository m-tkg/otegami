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

/// Uniform error body for every non-2xx relay response.
public struct RelayErrorResponse: Codable, Equatable, Sendable {
    public var error: String
    public var message: String

    public init(error: String, message: String) {
        self.error = error
        self.message = message
    }
}
