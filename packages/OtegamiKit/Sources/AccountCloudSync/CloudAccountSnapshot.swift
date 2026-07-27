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

    /// True when `imapHost` looks like a development/test mail server
    /// rather than a real one — a LAN address, loopback, or a `.test`/
    /// `.local` hostname. `AccountCloudSyncEngine.reconcile()`/
    /// `pushLocalChange` use this to keep this repo's own dev-mailstack
    /// accounts (`test1@otegami.test` on `localhost`/`192.168.x.x`, added
    /// by `scripts/verify-ios-*.sh`/XCUITests) out of the real iCloud KVS
    /// payload entirely.
    ///
    /// This exists because of a real-device incident
    /// (`docs/icloud-sync.md`'s "開発用アカウントの除外" section): a
    /// developer's own Mac is, by construction, signed into that
    /// developer's real Apple ID, and every local/Simulator build of this
    /// app shares the exact same `com.apple.developer.ubiquity
    /// -kvstore-identifier` (Team ID + bundle id) as the Ad-Hoc-signed
    /// build shipped to a real device (`make deploy-ota`) — there is no
    /// separate sandboxed iCloud a dev/verify run talks to instead.
    /// `AccountCloudSyncEngine.reconcile()`'s launch-time push therefore
    /// really did reach the real device's real iCloud KVS key, reseeding
    /// deleted dev accounts there every time a verify script or manual
    /// `make ios`/`make mac` run added one. This predicate is the second
    /// layer of defense (the first being `AppEnvironment`'s Simulator
    /// gate) — it also protects a Mac-native `make mac` run, which the
    /// Simulator gate alone can't, and doubles as the mechanism that
    /// scrubs already-contaminated cloud payload entries back out on the
    /// next `reconcile()` (see that method's phase 4).
    public var isDevelopmentAccount: Bool {
        Self.isDevelopmentHost(imapHost)
    }

    /// Pure host classifier backing `isDevelopmentAccount`, kept separate
    /// (and `static`, taking a plain `String`) so
    /// `CloudAccountSnapshotDevelopmentFilterTests` can exercise every
    /// boundary case — the three private-use IPv4 ranges (RFC 1918),
    /// loopback, `.test`/`.local` suffixes, and a battery of ordinary
    /// public hostnames that must *not* match — directly against host
    /// strings, without constructing a full snapshot for each one.
    static func isDevelopmentHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered.isEmpty { return false }
        if lowered == "localhost" { return true }
        if lowered.hasSuffix(".test") || lowered.hasSuffix(".local") { return true }

        // Only treat this as an IPv4-shaped host if all four dot-separated
        // parts parse as integers — anything else (an ordinary hostname
        // that happens to contain dots, say) falls through to `false`
        // below rather than being misread as a partial/invalid address.
        let parts = lowered.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4, let a = parts[0], let b = parts[1], parts[2] != nil, parts[3] != nil else {
            return false
        }
        if a == 127 { return true } // 127.0.0.0/8 — loopback
        if a == 10 { return true } // 10.0.0.0/8
        if a == 192, b == 168 { return true } // 192.168.0.0/16
        if a == 172, (16...31).contains(b) { return true } // 172.16.0.0/12
        return false
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
