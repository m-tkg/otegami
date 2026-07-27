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

    /// Account-level sync failure visibility (account edit UI): set when
    /// `SyncEngine.AccountSyncer` fails to even `connect()` (wrong
    /// password, unreachable host, ...) — as opposed to
    /// `MailboxRecord.lastSyncError`, which only ever gets a chance to be
    /// set *after* a successful connect, for a failure scoped to one
    /// mailbox. The account-edit flow's "change the password, save, see a
    /// visible failure, fix it, see it recover" verification loop
    /// (`docs/verify.md`) depends on a connect-level auth failure being
    /// visible somewhere — before this field existed, `AccountSyncer
    /// .performInitialSync`/`.performIncrementalSync` propagated it, but
    /// every real call site swallows that via `try?`
    /// (`OtegamiApp.syncAllAccountsOnce`, `AccountSetupView.saveAccount`,
    /// ...), so it never reached any UI. Mirrors `MailboxRecord
    /// .lastSyncError`'s "record it, clear it on the next success" shape.
    public var lastSyncError: String?
    public var lastSyncErrorAt: Date?

    /// D「アカウントのラベル色を変更可能に」(migration v22): a stable key
    /// naming one of `OtegamiAccountColor`'s eight fixed palette entries
    /// (e.g. `"teal"`, `"indigo"`) — a raw string, not the `Color` itself
    /// or an index, since `OtegamiStore` can't depend on the app-target-only
    /// `DesignSystem` module the palette lives in (same "mirror the type,
    /// don't import it" constraint `identityKey`'s doc comment already
    /// documents for `AccountCloudSync`). `nil` (the default for every
    /// account created before this column existed, and for any account
    /// whose user never picked a color) means "use the existing
    /// deterministic FNV-1a hash assignment" — `OtegamiAccountColor.color
    /// (for:override:)` is the single place that resolves this key (or its
    /// absence) to an actual `Color`. An unrecognized string (e.g. a future
    /// build's palette entry read by an older build) falls back to the
    /// same auto-assignment, never a crash.
    public var labelColorKey: String?

    /// F「デフォルト署名（アカウントごと）」(migration v24): which
    /// `SignatureTemplateRecord` `ComposerView` auto-inserts when this
    /// account is selected as From on a **brand-new** message (never for a
    /// reply/forward/draft — `ComposerView.loadAvailableSignatures()`'s doc
    /// comment on why that's scoped down). `nil` = no default (the
    /// Composer's "署名" picker still offers every signature scoped to this
    /// account, just starts at "なし"). `onDelete: .setNull` (the v24
    /// migration) means this self-heals to `nil` automatically if the
    /// referenced signature is ever deleted — never a dangling id.
    /// **Deliberately not part of `CloudAccountSnapshot`** — see the v24
    /// migration's doc comment for why this device-local id can't
    /// meaningfully sync between devices.
    public var defaultSignatureId: Int64?

    public var createdAt: Date

    /// M11 (iCloud account sync): when this row's synced metadata last
    /// changed. Used purely as `AccountCloudSync`'s last-writer-wins
    /// tiebreaker when the same account id has diverged copies on two
    /// devices — never read for anything else, so a coarse "set at
    /// creation, otherwise whenever a sync-relevant field changes" is
    /// precise enough (no need for per-field change tracking). Defaults to
    /// `createdAt`'s value for rows written before this column existed
    /// (`AppDatabase`'s v11 migration backfill).
    public var updatedAt: Date

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
        lastSyncError: String? = nil,
        lastSyncErrorAt: Date? = nil,
        labelColorKey: String? = nil,
        defaultSignatureId: Int64? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
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
        self.lastSyncError = lastSyncError
        self.lastSyncErrorAt = lastSyncErrorAt
        self.labelColorKey = labelColorKey
        self.defaultSignatureId = defaultSignatureId
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

extension AccountRecord {
    /// A case-insensitive "is this actually the same mailbox" key —
    /// mirrors `AccountCloudSync.CloudAccountSnapshot.identityKey` field for
    /// field (kept in sync by hand: `OtegamiStore` can't depend on
    /// `AccountCloudSync`, since the dependency direction runs the other
    /// way — `AccountCloudSync` already imports `OtegamiStore`). Used by
    /// `AccountDuplicateMerger` to find *already-local* duplicate account
    /// rows for the same real mailbox — the one-time migration side of
    /// `docs/icloud-sync.md`'s "重複挿入バグ" fix, for devices that hit the
    /// bug before `AccountCloudSyncEngine.reconcile()`'s phase 4 started
    /// preventing new duplicates from being inserted.
    public var identityKey: String {
        "\(authType.rawValue)|\(email.lowercased())|\(imapHost.lowercased())|\(imapUsername.lowercased())"
    }
}
