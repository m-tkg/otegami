import Testing
@testable import MailTransport

/// Task #119 (実機報告「その他 → Trash」): fixes the judgment table for
/// `MailboxRole.inferred(fromDisplayPath:)` — the SPECIAL-USE-less fallback
/// `MailCoreIMAPSession+Mapping.role(for:path:displayPath:)` uses when a
/// server (iCloud among real-world offenders) never advertises RFC 6154
/// SPECIAL-USE for a standard mailbox.
@Suite("MailboxRole.inferred(fromDisplayPath:)")
struct MailboxRoleNameInferenceTests {
    // MARK: - Trash

    @Test(
        "well-known Trash names",
        arguments: ["Trash", "trash", "TRASH", "Deleted Messages", "Deleted Items", "Bin", "ゴミ箱", "ごみ箱"]
    )
    func trashNames(_ name: String) {
        #expect(MailboxRole.inferred(fromDisplayPath: name) == .trash)
    }

    // MARK: - Junk

    @Test(
        "well-known Junk names",
        arguments: ["Junk", "Junk E-Mail", "Junk Email", "Spam", "spam", "迷惑メール"]
    )
    func junkNames(_ name: String) {
        #expect(MailboxRole.inferred(fromDisplayPath: name) == .junk)
    }

    // MARK: - Sent

    @Test(
        "well-known Sent names",
        arguments: ["Sent", "Sent Mail", "Sent Messages", "Sent Items", "送信済み", "送信済みメール", "送信済みアイテム"]
    )
    func sentNames(_ name: String) {
        #expect(MailboxRole.inferred(fromDisplayPath: name) == .sent)
    }

    // MARK: - Drafts

    @Test("well-known Drafts names", arguments: ["Drafts", "Draft", "下書き"])
    func draftsNames(_ name: String) {
        #expect(MailboxRole.inferred(fromDisplayPath: name) == .drafts)
    }

    // MARK: - Archive

    @Test("well-known Archive names", arguments: ["Archive", "Archives", "All Mail", "アーカイブ"])
    func archiveNames(_ name: String) {
        #expect(MailboxRole.inferred(fromDisplayPath: name) == .archive)
    }

    // MARK: - Namespaced paths (e.g. Courier-style INBOX.Trash, normalized to "/")

    @Test
    func matchesTheLastPathComponentOfANamespacedPath() {
        #expect(MailboxRole.inferred(fromDisplayPath: "INBOX/Trash") == .trash)
        #expect(MailboxRole.inferred(fromDisplayPath: "INBOX/Junk") == .junk)
        #expect(MailboxRole.inferred(fromDisplayPath: "INBOX/Sent Items") == .sent)
    }

    // MARK: - No match

    @Test(
        "user-created mailbox names never match",
        arguments: ["Work", "Family", "プロジェクトA", "Newsletters", ""]
    )
    func noMatch(_ name: String) {
        #expect(MailboxRole.inferred(fromDisplayPath: name) == .none)
    }

    /// A folder that happens to be *named* "INBOX" but isn't nested at the
    /// top (e.g. "Archive/INBOX") should not be inferred as the account's
    /// real inbox — `.inbox` is deliberately absent from this fallback's own
    /// name table; only the raw-path exact-match check in
    /// `MailCoreIMAPSession+Mapping.role(for:path:displayPath:)` grants that,
    /// and only for a top-level "INBOX".
    @Test
    func neverInfersInboxByName() {
        #expect(MailboxRole.inferred(fromDisplayPath: "INBOX") == .none)
        #expect(MailboxRole.inferred(fromDisplayPath: "Archive/INBOX") == .none)
    }
}
