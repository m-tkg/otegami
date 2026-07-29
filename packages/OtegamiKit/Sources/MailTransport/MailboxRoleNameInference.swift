/// Task #119 (実機報告: ハンバーガーメニューに「ゴミ箱 → Gmail」の統合セクション
/// がある一方、別に「その他 → Trash」も出る): a server that doesn't advertise
/// RFC 6154 `SPECIAL-USE` at all (or advertises an attribute
/// `MailCoreIMAPSession+Mapping.role(for:path:displayPath:)` doesn't map to a
/// `MailboxRole`) leaves that mailbox at `MailboxRole.none` — which the
/// hamburger menu's category grouping (`FolderListSheet.uncategorizedSection`)
/// dumps into "その他" instead of the unified "ゴミ箱"/"迷惑メール"/... section
/// every other account's same-purpose mailbox appears in. iCloud's IMAP server
/// and plenty of generic/self-hosted IMAP servers (unlike Gmail and the dev
/// mailstack's Dovecot, both SPECIAL-USE-capable) fall into exactly this gap.
///
/// This is the backend-agnostic fallback: given a mailbox's already-decoded,
/// delimiter-normalized display path (`MailboxInfo.displayPath` — "/"
/// throughout regardless of the server's actual hierarchy delimiter, so a
/// namespaced path like the Courier convention's `INBOX.Trash` reads the same
/// as a flat `Trash`), match its last path component against the well-known
/// names real-world servers use for their standard mailboxes across the
/// languages this app localizes into (English, Japanese). Deliberately a
/// closed, hardcoded name list rather than any kind of fuzzy match — a wrong
/// guess here silently mis-files a user's mailbox into the wrong unified
/// section, which is worse than leaving it in "その他" (`MailboxRole.none`)
/// where the true fallback below always lands only when nothing matches.
///
/// Kept in `MailTransport` (Linux-compatible, no MailCore2 dependency) rather
/// than inline in `MailTransportMailCore` so it's unit-testable without
/// linking MailCore2 or a real IMAP server — see `MailTransportTests`.
public extension MailboxRole {
    /// One name-lookup table per role, all entries pre-lowercased (matching
    /// is always done against a lowercased candidate — see `inferred(fromDisplayPath:)`).
    /// Order among these tables doesn't matter (a real mailbox name should
    /// never plausibly match two different roles' name sets at once), but
    /// `inferred(fromDisplayPath:)` still checks them in a fixed order for
    /// determinism.
    private static let trashNames: Set<String> = [
        "trash", "deleted messages", "deleted items", "bin",
        "ゴミ箱", "ごみ箱",
    ]
    private static let junkNames: Set<String> = [
        "junk", "junk e-mail", "junk email", "spam",
        "迷惑メール",
    ]
    private static let sentNames: Set<String> = [
        "sent", "sent mail", "sent messages", "sent items",
        "送信済み", "送信済みメール", "送信済みアイテム",
    ]
    private static let draftsNames: Set<String> = [
        "drafts", "draft",
        "下書き",
    ]
    private static let archiveNames: Set<String> = [
        "archive", "archives", "all mail",
        "アーカイブ",
    ]

    /// Returns the role inferred from `displayPath`'s last path component's
    /// name, or `.none` if it doesn't match any of the well-known names
    /// above (i.e. this really is a user-created/uncategorizable mailbox).
    /// Callers should only fall back to this once every SPECIAL-USE
    /// attribute (and, for `.inbox`, IMAP's own guaranteed-meaning "INBOX"
    /// path check) has already come back empty — SPECIAL-USE, when
    /// advertised, is always authoritative over a name guess.
    static func inferred(fromDisplayPath displayPath: String) -> MailboxRole {
        let lastComponent = displayPath.split(separator: "/").last.map(String.init) ?? displayPath
        let normalized = lastComponent.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.isEmpty else { return .none }

        if trashNames.contains(normalized) { return .trash }
        if junkNames.contains(normalized) { return .junk }
        if sentNames.contains(normalized) { return .sent }
        if draftsNames.contains(normalized) { return .drafts }
        if archiveNames.contains(normalized) { return .archive }
        return .none
    }
}
