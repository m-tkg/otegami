import Foundation
import OtegamiStore

/// The non-secret slice of `OtegamiStore.AccountRecord` that gets synced
/// through iCloud's key-value store (`AccountCloudSyncEngine`). Deliberately
/// excludes anything a credential: the IMAP/SMTP password lives in Keychain
/// (already iCloud-Keychain-synced on its own — see
/// `KeychainCredentialStore`'s doc comment), the Gmail refresh token in
/// `GoogleOAuth.TokenStore`/Keychain, and `AccountRecord.needsReauth` is
/// deliberately device-local (whether *this* device currently has a usable
/// credential says nothing about any other device's Keychain state).
///
/// Field-for-field this mirrors every column of `account` that isn't a
/// secret and isn't purely local bookkeeping, so a snapshot round-trips
/// through `makeAccountRecord()`/`apply(to:)` without losing anything a
/// freshly-added account on another device would have set.
public struct CloudAccountSnapshot: Codable, Equatable, Sendable {
    public var accountId: String
    public var displayName: String
    public var email: String
    public var authType: AccountAuthType
    public var kind: AccountKind
    public var imapHost: String
    public var imapPort: Int
    public var imapSecurity: ConnectionSecurityRecord
    public var imapAllowsInsecureTLS: Bool
    public var imapUsername: String
    public var smtpHost: String?
    public var smtpPort: Int?
    public var smtpSecurity: ConnectionSecurityRecord?
    public var smtpAllowsInsecureTLS: Bool
    public var smtpUsername: String?
    public var createdAt: Date
    /// `AccountCloudSyncEngine`'s last-writer-wins tiebreaker — see
    /// `AccountRecord.updatedAt`'s doc comment.
    public var updatedAt: Date

    public init(
        accountId: String,
        displayName: String,
        email: String,
        authType: AccountAuthType,
        kind: AccountKind,
        imapHost: String,
        imapPort: Int,
        imapSecurity: ConnectionSecurityRecord,
        imapAllowsInsecureTLS: Bool,
        imapUsername: String,
        smtpHost: String?,
        smtpPort: Int?,
        smtpSecurity: ConnectionSecurityRecord?,
        smtpAllowsInsecureTLS: Bool,
        smtpUsername: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.accountId = accountId
        self.displayName = displayName
        self.email = email
        self.authType = authType
        self.kind = kind
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
        self.updatedAt = updatedAt
    }
}

extension CloudAccountSnapshot {
    /// Captures every synced field of `account` as it stands right now —
    /// called both when pushing a locally-created/changed account to the
    /// cloud and when `AccountCloudSyncEngine.reconcile()` asks
    /// `LocalAccountDirectory.allAccountSnapshots()` for the current local
    /// state to diff against the cloud payload.
    public init(account: AccountRecord) {
        self.init(
            accountId: account.id,
            displayName: account.displayName,
            email: account.email,
            authType: account.authType,
            kind: account.kind,
            imapHost: account.imapHost,
            imapPort: account.imapPort,
            imapSecurity: account.imapSecurity,
            imapAllowsInsecureTLS: account.imapAllowsInsecureTLS,
            imapUsername: account.imapUsername,
            smtpHost: account.smtpHost,
            smtpPort: account.smtpPort,
            smtpSecurity: account.smtpSecurity,
            smtpAllowsInsecureTLS: account.smtpAllowsInsecureTLS,
            smtpUsername: account.smtpUsername,
            createdAt: account.createdAt,
            updatedAt: account.updatedAt
        )
    }

    /// Builds a brand-new `AccountRecord` for a cloud-discovered account
    /// that doesn't exist locally yet (`LocalAccountDirectory
    /// .insertFromCloud`). `needsReauth` is intentionally left at its
    /// default (`false`) here — the caller (the app's `LocalAccountDirectory`
    /// implementation) sets it based on whether a usable Keychain credential
    /// was actually found on *this* device, which this snapshot has no way
    /// to know.
    public func makeAccountRecord() -> AccountRecord {
        AccountRecord(
            id: accountId,
            displayName: displayName,
            email: email,
            authType: authType,
            kind: kind,
            imapHost: imapHost,
            imapPort: imapPort,
            imapSecurity: imapSecurity,
            imapAllowsInsecureTLS: imapAllowsInsecureTLS,
            imapUsername: imapUsername,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            smtpSecurity: smtpSecurity,
            smtpAllowsInsecureTLS: smtpAllowsInsecureTLS,
            smtpUsername: smtpUsername,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Overwrites every synced field of an *existing* local `AccountRecord`
    /// with this (newer, per last-writer-wins) cloud snapshot
    /// (`LocalAccountDirectory.updateFromCloud`). Leaves `id` (the merge
    /// key) and `needsReauth` (device-local credential state) untouched.
    public func apply(to account: inout AccountRecord) {
        account.displayName = displayName
        account.email = email
        account.authType = authType
        account.kind = kind
        account.imapHost = imapHost
        account.imapPort = imapPort
        account.imapSecurity = imapSecurity
        account.imapAllowsInsecureTLS = imapAllowsInsecureTLS
        account.imapUsername = imapUsername
        account.smtpHost = smtpHost
        account.smtpPort = smtpPort
        account.smtpSecurity = smtpSecurity
        account.smtpAllowsInsecureTLS = smtpAllowsInsecureTLS
        account.smtpUsername = smtpUsername
        account.createdAt = createdAt
        account.updatedAt = updatedAt
    }
}
