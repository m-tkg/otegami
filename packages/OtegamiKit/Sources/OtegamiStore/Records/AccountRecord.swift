import Foundation
import GRDB

/// Mirrors `MailTransport.MailAuth`'s cases without depending on
/// `MailTransport` (`OtegamiStore` only depends on `OtegamiCore`, per the
/// plan's dependency direction: `SyncEngine → OtegamiStore → OtegamiCore`,
/// separately from `SyncEngine → MailTransport`). `SyncEngine`/the app map
/// between the two where credentials actually get supplied to a session.
public enum AccountAuthType: String, Codable, Sendable {
    /// Plain username/password (`LOGIN`), used by generic IMAP/SMTP,
    /// iCloud, and the dev mailstack. The password itself is never stored
    /// here — it lives in Keychain, keyed by `AccountRecord.id`.
    case password
    /// `XOAUTH2`, used by Gmail (M6). Reserved for forward compatibility;
    /// unused until then.
    case oauth2
}

/// Mirrors `MailTransport.MailConnectionSecurity` without depending on
/// `MailTransport`. See `AccountAuthType`.
public enum ConnectionSecurityRecord: String, Codable, Sendable {
    case plain
    case tls
    case startTLS
}

/// Which mail provider this account is (M5 forward-compat for M6's Gmail
/// OAuth + iCloud presets): today every account is `.generic` (the only
/// kind M1–M5 create), but `OpQueueProcessor`'s `.send` replay already
/// needs to branch on it (plan: "Sent へ IMAP APPEND ... Gmail kind ならスキップ,
/// 判定は account.kind") — Gmail auto-saves a sent copy itself via SMTP
/// submission, so an explicit client-side APPEND would double it. Adding
/// the column now (default `"generic"`, migration v5) means M6 only needs
/// to start writing `.gmail`/`.icloud`, not retrofit a schema change.
public enum AccountKind: String, Codable, Sendable {
    case generic
    case gmail
    case icloud
}

/// A configured mail account. Credentials are never stored here: passwords
/// live in Keychain (keyed by `id`), OAuth tokens in `TokenStore` (M6). Only
/// `authType` — which kind of credential to look up — is persisted.
public struct AccountRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "account"

    public var id: String
    public var displayName: String
    public var email: String
    public var authType: AccountAuthType
    /// Defaults to `.generic` — see `AccountKind`'s doc comment. Not user-
    /// editable in M1–M5's plain IMAP/SMTP setup form; M6's Gmail/iCloud
    /// preset flows are what set this to anything else.
    public var kind: AccountKind

    /// M6: set when `GoogleOAuth.TokenStore.accessToken(for:)` throws
    /// `.reauthenticationRequired` (the stored refresh token was rejected —
    /// revoked, expired, or the user changed their Google password).
    /// `AppEnvironment.auth(for:)` sets this; `AccountsSettingsView` reads
    /// it to show a "再認証が必要です" banner + button that re-runs
    /// `GoogleOAuthClient.requestAuthorization()` and clears it again. Only
    /// ever meaningful for `.gmail`-kind accounts — a `.password` account
    /// has no refresh token to go stale, so this simply never gets set for
    /// one.
    public var needsReauth: Bool

    public var imapHost: String
    public var imapPort: Int
    public var imapSecurity: ConnectionSecurityRecord
    public var imapAllowsInsecureTLS: Bool
    public var imapUsername: String

    /// SMTP settings are collected in the account setup form (M1) but not
    /// exercised until M5 (Compose/Reply/SMTP); optional so a partially
    /// filled form doesn't block saving the account.
    public var smtpHost: String?
    public var smtpPort: Int?
    public var smtpSecurity: ConnectionSecurityRecord?
    public var smtpAllowsInsecureTLS: Bool
    public var smtpUsername: String?

    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        email: String,
        authType: AccountAuthType,
        kind: AccountKind = .generic,
        needsReauth: Bool = false,
        imapHost: String,
        imapPort: Int,
        imapSecurity: ConnectionSecurityRecord,
        imapAllowsInsecureTLS: Bool = false,
        imapUsername: String,
        smtpHost: String? = nil,
        smtpPort: Int? = nil,
        smtpSecurity: ConnectionSecurityRecord? = nil,
        smtpAllowsInsecureTLS: Bool = false,
        smtpUsername: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.authType = authType
        self.kind = kind
        self.needsReauth = needsReauth
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapSecurity = imapSecurity
        self.imapAllowsInsecureTLS = imapAllowsInsecureTLS
        self.imapUsername = imapUsername
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpSecurity = smtpSecurity
        self.smtpAllowsInsecureTLS = smtpAllowsInsecureTLS
        self.smtpUsername = smtpUsername
        self.createdAt = createdAt
    }
}
