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

/// A configured mail account. Credentials are never stored here: passwords
/// live in Keychain (keyed by `id`), OAuth tokens in `TokenStore` (M6). Only
/// `authType` — which kind of credential to look up — is persisted.
public struct AccountRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "account"

    public var id: String
    public var displayName: String
    public var email: String
    public var authType: AccountAuthType

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
