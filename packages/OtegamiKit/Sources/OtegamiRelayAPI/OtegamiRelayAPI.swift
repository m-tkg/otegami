import Foundation

// DTOs used by the app (`apps/Otegami`) to communicate with the Go push
// relay (`server/otegami-relay-go`). Linux-compatible (Foundation only);
// its Codable wire format is locked against the Go DTOs by
// `OtegamiRelayAPITests`.
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
/// v1 supported `.password` only (plan: "LOGIN/XOAUTH2 なし可: password
/// のみ v1"); Task #175 added `.oauth` so Gmail/Outlook (`.oauth2` local
/// accounts) can get push watches too, at the cost of the relay holding a
/// refresh token instead of an IMAP password — see
/// `docs/relay-deployment.md`'s threat model for what that changes.
public struct WatchAuth: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case password
        /// XOAUTH2 — `secret` is an OAuth refresh token, `provider` says
        /// which token endpoint the relay must exchange it at
        /// (`WatcherPool`/`OAuthTokenExchanger`). Required to be paired
        /// with a non-`nil` `provider` — `WatchRoutes` rejects a
        /// `.oauth` request with no `provider` at creation time.
        case oauth
    }

    /// Which OAuth provider issued `secret` when `type == .oauth` — the
    /// relay needs this to pick the right token endpoint/client id
    /// (`RelayConfiguration.googleOAuthClientId`/`microsoftOAuthClientId`).
    /// Always `nil` for `.password`.
    public enum Provider: String, Codable, Sendable {
        case google
        case microsoft
    }

    public var type: Kind
    /// The IMAP password (`.password`) or an OAuth refresh token
    /// (`.oauth`). Sent once over TLS at watch-creation time; the server
    /// encrypts it at rest (`CredentialCrypto`) and never echoes it back
    /// in any response.
    public var secret: String
    /// Required (and validated by `WatchRoutes`) when `type == .oauth`;
    /// otherwise `nil`.
    public var provider: Provider?

    public init(type: Kind = .password, secret: String, provider: Provider? = nil) {
        self.type = type
        self.secret = secret
        self.provider = provider
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

/// Body of the push payload the relay sends to APNs, and that
/// `NotificationService` parses back out of `content-available`/
/// `mutable-content` `userInfo`. `accountId`/`uidNext` are the original
/// content-free fields (plan: "本文/件名を含めない") and are never omitted;
/// every other field is an opt-in addition (`RELAY_CONTENT_PREVIEW`,
/// `docs/relay-deployment.md`) only ever populated when that relay-side
/// feature is on and its cycle's UID FETCH succeeded — mirrors Go's
/// `api.PushNotificationPayload` (`server/otegami-relay-go/internal/api/dto.go`)
/// field-for-field, including which fields are `omitempty` there. Declaring
/// these as plain `Optional` properties is enough for Swift's synthesized
/// `Codable` to match Go's `omitempty` on encode (an `Optional` property
/// encodes via `encodeIfPresent`, omitting the key entirely when `nil`) and
/// to decode an older/newer peer leniently (a missing key decodes to `nil`
/// via `decodeIfPresent` rather than throwing) — no custom `init(from:)`/
/// `encode(to:)` needed, unlike `WatchSummary`'s hand-rolled leniency for
/// unrecognized *enum* raw values.
///
/// Push 通知起点バックグラウンド受信 Phase 3 (リレー先読み統合):
/// `NotificationService.enrich(payload:)` uses `latestFromName`/
/// `latestFromAddress`/`latestSubject` to build the notification's title/
/// body immediately, with zero network calls, before its usual sync-first
/// work even starts — guaranteeing display within its 5 second budget even
/// when the network is slow. `latestUid` is the anchor `GET /v1/messages`
/// (`PushRelayClient.fetchMessagePreviews(...)`) uses to additionally fetch
/// that same message's `bodyPreview`, and `previewCount` is diagnostic only
/// (never read by the app). An older app build that only ever reads
/// `accountId`/`uidNext` keeps working unmodified against a relay that has
/// this feature enabled — and a build with this Phase 3 support keeps
/// working unmodified against an older/`RELAY_CONTENT_PREVIEW`-off relay,
/// which never sends these fields at all.
public struct PushNotificationPayload: Codable, Equatable, Sendable {
    public var accountId: String
    public var uidNext: Int
    /// The single newest message in this push cycle's fetched range — a
    /// push payload has no room (APNs caps the whole JSON body at 4KB) for
    /// a full list; `GET /v1/messages` is where the app fetches the rest
    /// (`PushRelayClient.fetchMessagePreviews(...)`).
    public var latestUid: Int64?
    public var latestFromName: String?
    public var latestFromAddress: String?
    public var latestSubject: String?
    /// How many messages this cycle's UID FETCH actually produced a
    /// preview for (may be less than the new-mail count if some individual
    /// messages failed to parse relay-side) — diagnostic only, `enrich(payload:)`
    /// never reads this.
    public var previewCount: Int?

    public init(
        accountId: String,
        uidNext: Int,
        latestUid: Int64? = nil,
        latestFromName: String? = nil,
        latestFromAddress: String? = nil,
        latestSubject: String? = nil,
        previewCount: Int? = nil
    ) {
        self.accountId = accountId
        self.uidNext = uidNext
        self.latestUid = latestUid
        self.latestFromName = latestFromName
        self.latestFromAddress = latestFromAddress
        self.latestSubject = latestSubject
        self.previewCount = previewCount
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
    /// Whether the relay's per-watch loop (`server/otegami-relay-go`) is
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
        /// Task #175 (OAuth watches): the stored refresh token was
        /// rejected by the provider's token endpoint (`invalid_grant` —
        /// revoked/expired) while exchanging it for an access token.
        /// Unlike `.authFailure`, this stops the watch immediately rather
        /// than after `maxConsecutiveAuthFailures` — a dead refresh token
        /// never recovers on its own, so retrying gains nothing. Fixing
        /// this requires re-authenticating the account in the app (which
        /// mints a fresh refresh token), then re-registering the watch —
        /// the same "再登録" flow `.authFailure` already uses.
        case oauthTokenExpired
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
        // the whole list. `status`/`lastErrorKind` go one step further
        // (Task #208 fragility fix, see below): they tolerate a key that's
        // *present* but holds a raw string this build doesn't recognize
        // yet, not just a missing key.
        status = try Self.decodeLenientRawEnum(Status.self, from: container, forKey: .status) ?? .active
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        lastErrorKind = try Self.decodeLenientRawEnum(ErrorKind.self, from: container, forKey: .lastErrorKind)
        lastErrorAt = try container.decodeIfPresent(Date.self, forKey: .lastErrorAt)
    }

    /// Decodes a `String`-backed enum field leniently: missing key -> nil
    /// (same as `decodeIfPresent`), key present but its value is a raw
    /// string this build's enum doesn't recognize -> nil instead of
    /// throwing.
    ///
    /// Plain `container.decodeIfPresent(SomeRawEnum.self, forKey:)` only
    /// covers the "key absent" case — `RawRepresentable`'s synthesized
    /// `init(from:)` still throws `DecodingError.dataCorrupted` for "key
    /// present, but its string isn't one of the enum's cases", and that
    /// error isn't swallowed by `decodeIfPresent`, so it fails the whole
    /// `WatchSummary`, which in turn fails the whole `GET /v1/watches`
    /// array decode (`JSONDecoder` has no per-element recovery). Before
    /// this helper existed, that was a real constraint on the relay: Task
    /// #206 explicitly avoided introducing a new `lastErrorKind` wire value
    /// for exactly this reason (see docs/architecture.md's pitfall "i."),
    /// because an already-shipped app talking to a newly-upgraded relay
    /// would have its watch list reads start failing outright the moment
    /// the relay returned a value this build had never heard of. Task #208
    /// added this so a relay is free to introduce a new `status`/
    /// `lastErrorKind` value in the future without that same constraint —
    /// an unrecognized value just reads as "unknown" (nil) instead of
    /// corrupting the whole response.
    private static func decodeLenientRawEnum<T: RawRepresentable & Decodable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> T? where T.RawValue == String {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return T(rawValue: raw)
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

/// `GET /v1/messages`'s response is a plain JSON array of these — one
/// decrypted, best-effort content preview per recently-seen message on the
/// requested watch (`RELAY_CONTENT_PREVIEW`, opt-in). Mirrors Go's
/// `api.MessagePreviewSummary` field-for-field (same file/package as
/// `PushNotificationPayload`'s doc comment). Every field is required
/// (non-`omitempty` on the Go side) — a preview the server includes at all
/// always has all of these, even if some are empty strings (e.g. a message
/// with no display name in its `From` header).
public struct MessagePreview: Codable, Equatable, Sendable, Identifiable {
    /// Mirrors Go's `api.MessagePreviewFrom` — deliberately its own small
    /// type rather than reusing `OtegamiCore.EmailAddress` (whose `name` is
    /// `String?`, `nil` meaning "no display name"): this package has no
    /// dependency on `OtegamiCore` at all (this file's own doc comment,
    /// "Linux-compatible (Foundation only)"), and the wire shape here is a
    /// non-optional (possibly empty) `name` string, not an omittable one.
    public struct From: Codable, Equatable, Sendable {
        public var name: String
        public var address: String

        public init(name: String, address: String) {
            self.name = name
            self.address = address
        }
    }

    public var uid: Int64
    public var from: From
    public var subject: String
    public var date: Date
    public var messageId: String
    public var bodyPreview: String

    public var id: Int64 { uid }

    public init(uid: Int64, from: From, subject: String, date: Date, messageId: String, bodyPreview: String) {
        self.uid = uid
        self.from = from
        self.subject = subject
        self.date = date
        self.messageId = messageId
        self.bodyPreview = bodyPreview
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
