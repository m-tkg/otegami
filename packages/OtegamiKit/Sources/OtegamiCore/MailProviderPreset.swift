import Foundation

/// Task #116「アカウント追加画面のプロバイダ拡充」: the connection-security
/// tier a `MailServerPreset` targets. Mirrors `OtegamiStore
/// .ConnectionSecurityRecord`'s three cases without depending on
/// `OtegamiStore` — this file lives in `OtegamiCore` (Linux-compatible,
/// zero-dependency pure-logic layer, same rationale as `FreeMailDomains`)
/// so the preset data itself is unit-testable via a plain `swift test`
/// without pulling in GRDB. The app layer (`AccountSetupView`/
/// `YahooAccountSetupView`/`YahooJapanAccountSetupView`) maps this to the
/// real `ConnectionSecurityRecord` at the one point it actually builds an
/// `AccountRecord`.
public enum MailConnectionSecurityKind: String, Sendable, Equatable {
    case plain
    case startTLS
    case tls
}

/// One endpoint (IMAP or SMTP) of a `MailProviderPreset`.
public struct MailServerPreset: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var security: MailConnectionSecurityKind

    public init(host: String, port: Int, security: MailConnectionSecurityKind) {
        self.host = host
        self.port = port
        self.security = security
    }
}

/// A named mail provider's IMAP/SMTP preset — what
/// `AccountTypeSelectionView`'s Yahoo / Yahoo! JAPAN / Exchange buttons
/// each pre-fill their form with (plan: "ホスト・ポートは事前入力された
/// 状態にする"). Gmail/iCloud already had their own presets hardcoded
/// directly in `GmailAccountSetupView`/`ICloudAccountSetupView` before this
/// task (M6) — those two are intentionally left as-is (not migrated here)
/// to keep this change's diff scoped to the providers actually being added;
/// see `docs/design-system.md`'s Task #116 note for the rationale.
public struct MailProviderPreset: Sendable, Equatable, Identifiable {
    public var id: String
    /// The email domain this provider owns, when it's fixed (e.g.
    /// `"yahoo.com"`) — `nil` for a provider like Exchange where the host
    /// (and therefore the domain) is always the user's own organization's,
    /// never a fixed value this preset could know ahead of time.
    public var emailDomainHint: String?
    public var imap: MailServerPreset
    public var smtp: MailServerPreset

    public init(id: String, emailDomainHint: String?, imap: MailServerPreset, smtp: MailServerPreset) {
        self.id = id
        self.emailDomainHint = emailDomainHint
        self.imap = imap
        self.smtp = smtp
    }
}

public enum MailProviderPresets {
    /// Yahoo Mail (yahoo.com) — requires an app-specific password (Yahoo's
    /// account security settings), never the account password itself; the
    /// setup form's guidance text covers that, this preset only carries the
    /// server settings. Port 465 is Yahoo's documented SMTP-over-implicit-TLS
    /// port (not STARTTLS on 587) — matches Yahoo's own published IMAP/SMTP
    /// settings.
    public static let yahoo = MailProviderPreset(
        id: "yahoo",
        emailDomainHint: "yahoo.com",
        imap: MailServerPreset(host: "imap.mail.yahoo.com", port: 993, security: .tls),
        smtp: MailServerPreset(host: "smtp.mail.yahoo.com", port: 465, security: .tls)
    )

    /// Yahoo!メール (yahoo.co.jp) — a separate service from international
    /// Yahoo Mail with its own IMAP/SMTP hosts. Requires 「メールソフトでの
    /// 利用設定 (IMAP アクセス)」to be enabled from the Yahoo!メール web UI
    /// before an IMAP client can connect at all (the setup form's guidance
    /// text covers this) — unlike international Yahoo, an app-specific
    /// password isn't the blocker here.
    public static let yahooJapan = MailProviderPreset(
        id: "yahooJapan",
        emailDomainHint: "yahoo.co.jp",
        imap: MailServerPreset(host: "imap.mail.yahoo.co.jp", port: 993, security: .tls),
        smtp: MailServerPreset(host: "smtp.mail.yahoo.co.jp", port: 465, security: .tls)
    )

    /// On-premises Microsoft Exchange with IMAP enabled — unlike every
    /// other preset here, the host is never known ahead of time (it's each
    /// organization's own mail server), so this only pre-fills port/security
    /// defaults on top of the generic "その他 (IMAP)" form
    /// (`AccountSetupView`'s `preset:` initializer parameter) rather than
    /// being a fully separate setup screen. STARTTLS-on-993 (not the more
    /// common implicit-TLS-on-993) is the assumption here specifically
    /// because a typical on-prem Exchange IMAP deployment fronts port 993
    /// with STARTTLS via IIS/Exchange's own TLS termination rather than a
    /// dedicated implicit-TLS listener — still just a starting point the
    /// generic form's security picker lets the user override if their
    /// server differs.
    public static let exchange = MailProviderPreset(
        id: "exchange",
        emailDomainHint: nil,
        imap: MailServerPreset(host: "", port: 993, security: .startTLS),
        smtp: MailServerPreset(host: "", port: 587, security: .startTLS)
    )
}
