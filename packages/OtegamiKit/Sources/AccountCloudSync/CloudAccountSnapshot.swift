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
    /// D「アカウントのラベル色を変更可能に」— see `AccountRecord.labelColorKey`'s
    /// doc comment. Synced like every other non-secret field so a
    /// manually-picked color travels between devices (`docs/icloud-sync.md`).
    public var labelColorKey: String?
    /// アカウント並び替え — see `AccountRecord.sortOrder`'s doc comment for
    /// why this one (unlike `defaultSignatureId`) is synced: it's a UI
    /// position both devices agree names the same account, not a
    /// device-local id.
    public var sortOrder: Int
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
        labelColorKey: String? = nil,
        sortOrder: Int = 0,
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
        self.labelColorKey = labelColorKey
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension CloudAccountSnapshot {
    /// A case-insensitive "is this actually the same mailbox" key, used by
    /// `AccountCloudSyncEngine.reconcile()`'s phase 4 to recognize a cloud
    /// account as a duplicate of one this device already knows about under
    /// a *different* `accountId` — see that method's doc comment for the
    /// bug this fixes (`docs/icloud-sync.md`'s "重複挿入バグ"): two devices
    /// each adding "the same" mail account independently generate two
    /// different UUIDs for `AccountRecord.id`, so matching on `accountId`
    /// alone treats them as unrelated and inserts both, producing a visible
    /// duplicate in the account list plus duplicate mail in the unified
    /// inbox (one copy per duplicate account).
    ///
    /// `authType` is included as a safety guard, not part of the literal
    /// "same mailbox" definition — it prevents ever merging a `.password`
    /// account into an `.oauth2` one (or vice versa) purely because their
    /// email/host/username happen to coincide; the two use entirely
    /// different credential machinery (Keychain password vs. `TokenStore`
    /// refresh token), so treating them as interchangeable would be a
    /// correctness bug of its own, not a fix. `email`/`imapHost`/
    /// `imapUsername` are lowercased before comparing (domains and email
    /// local parts are conventionally case-insensitive, and this errs
    /// toward *catching* a duplicate rather than missing one over a casing
    /// difference); `smtpHost`/display name are deliberately excluded — a
    /// user could plausibly reconfigure SMTP or rename an account on one
    /// device without that meaning it's now a "different" mailbox.
    var identityKey: String {
        "\(authType.rawValue)|\(email.lowercased())|\(imapHost.lowercased())|\(imapUsername.lowercased())"
    }

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
            labelColorKey: account.labelColorKey,
            sortOrder: account.sortOrder,
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
            labelColorKey: labelColorKey,
            sortOrder: sortOrder,
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
        account.labelColorKey = labelColorKey
        account.sortOrder = sortOrder
        account.createdAt = createdAt
        account.updatedAt = updatedAt
    }
}
