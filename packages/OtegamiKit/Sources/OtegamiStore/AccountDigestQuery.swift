import Foundation
import GRDB
import OtegamiCore

/// Task #92 (アカウントダイジェスト画面): one row's worth of per-account
/// summary data for `AccountDigestView` (the app target's replacement for
/// #77's inline `AccountGroupSectionHeader` — see that view's removal doc
/// comment in `MessageListView.swift`). A digest row shows an account's
/// color rail, display name, unread/total counts, and a couple of recent
/// subject-preview lines — everything here is what backs those without a
/// SwiftUI host, so the counting/ordering logic itself is unit-testable.
public struct AccountDigest: Sendable, Equatable, Identifiable {
    public var accountId: String
    /// Every thread in scope (the digest's `role`, across just this one
    /// account) — independent of the list's own 未読のみ表示
    /// (`ListDisplaySettingsStore.unreadOnlyKey`) toggle. The digest screen
    /// is a cross-account overview reached from either state of that
    /// toggle; scoping its own counts to "whatever the list happened to be
    /// filtered to when the user tapped グループ化" would make the same
    /// account look like it has different mail depending on an unrelated,
    /// transient per-session setting. Drilling back into the filtered list
    /// (`onSelectAccount`) still respects that toggle exactly as before —
    /// only this overview's own counts are deliberately unfiltered by it.
    public var totalCount: Int
    /// The number of *unread messages whose own mailbox is in this digest's
    /// `role` scope* — closer to what a notification-style badge
    /// conventionally means ("12 unread messages"), and distinct from
    /// `totalCount` (a thread/conversation count).
    ///
    /// Task #137 (実機報告「『すべてのアーカイブ』のダイジェストで、各行の
    /// バッジがボックス無関係の値」): this used to be
    /// `ThreadRecord.unreadCount` summed across `threads` — but that field
    /// is a **thread-wide** aggregate (`ThreadRecord.unreadCount`'s own doc
    /// comment: "how many of this thread's messages are currently unread",
    /// counted over *every* mailbox the thread has a message in, not just
    /// the one this digest is scoped to). `ThreadQuery.unifiedInboxRequest`'s
    /// own doc comment records that a thread "can span mailboxes, e.g.
    /// Inbox + Sent" — Gmail's label model makes this common (the same
    /// message appears in INBOX and, once archived, only in All Mail, but a
    /// reply the user sent stays in Sent while the rest of the thread moves
    /// to Archive). So a thread with one unread message still sitting in
    /// INBOX and one already-read message in Archive would count toward
    /// the *archive* digest's `unreadCount` too (the thread qualifies for
    /// the archive scope via the EXISTS membership check `unifiedInboxRequest`
    /// uses for `totalCount`), even though nothing in the archive itself is
    /// unread — exactly "a value unrelated to this box" the report
    /// described. Fixed by counting unread *messages* directly scoped to
    /// this `role` (`MessageQuery.unifiedInboxUnreadCount`, the same
    /// message-level/role-scoped/Gmail-All-Mail-aware query the folder
    /// list's own unread badges use) instead of summing the thread-wide
    /// aggregate.
    public var unreadCount: Int
    /// The newest `recentLimit` threads (same ordering as
    /// `ThreadQuery.unifiedInboxRequest`: pinned first, then by
    /// `lastMessageDate` desc) — what the row's subject-preview lines show.
    /// Capped independently of `totalCount`/`unreadCount`, which always
    /// reflect the *full* scope regardless of this limit.
    public var recentSummaries: [ThreadSummary]

    public var id: String { accountId }

    public init(accountId: String, totalCount: Int, unreadCount: Int, recentSummaries: [ThreadSummary]) {
        self.accountId = accountId
        self.totalCount = totalCount
        self.unreadCount = unreadCount
        self.recentSummaries = recentSummaries
    }
}

/// Query helpers behind `AccountDigest` — kept in `OtegamiStore` (not the
/// app target), same reasoning as `ThreadQuery`/`MessageRemoval`: a plain
/// `AppDatabase.makeInMemory()` unit test can exercise the counting/
/// ordering/scoping logic with no SwiftUI host at all
/// (`AccountDigestQueryTests`).
public enum AccountDigestQuery {
    /// 2–3件 per the Task #92 spec ("直近メールの件名プレビューを数件
    /// (2-3件)") — the middle of that range.
    public static let defaultRecentLimit = 3

    /// One `AccountDigest` per id in `accountIds`, in the same order —
    /// every account is included even with zero matching threads (a "0件"
    /// row still tells the user that account is caught up, rather than
    /// silently vanishing from the digest and reading as "did this account
    /// disappear?").
    public static func digests(accountIds: [String], role: MailboxRoleRecord = .inbox, recentLimit: Int = defaultRecentLimit, db: Database) throws -> [AccountDigest] {
        try accountIds.map { accountId in
            let threads = try ThreadQuery.unifiedInboxRequest(accountIds: [accountId], role: role).fetchAll(db)
            // Task #137: message-level, role-scoped unread count — see
            // `AccountDigest.unreadCount`'s doc comment for why this can't
            // be `threads.reduce(0) { $0 + $1.unreadCount }` (that field is
            // a thread-wide aggregate, not scoped to this `role`).
            let unreadCount = try MessageQuery.unifiedInboxUnreadCount(accountIds: [accountId], role: role, db: db)
            let recentSummaries = try ThreadQuery.summaries(forThreads: Array(threads.prefix(recentLimit)), db: db)
            return AccountDigest(accountId: accountId, totalCount: threads.count, unreadCount: unreadCount, recentSummaries: recentSummaries)
        }
    }

    public static func digestsObservation(accountIds: [String], role: MailboxRoleRecord = .inbox, recentLimit: Int = defaultRecentLimit) -> ValueObservation<ValueReducers.Fetch<[AccountDigest]>> {
        ValueObservation.tracking { db in try digests(accountIds: accountIds, role: role, recentLimit: recentLimit, db: db) }
    }

    /// Every thread for one account in `role` scope, as `ThreadSummary`s —
    /// what a digest row's swipe-to-bulk-process action
    /// (`AccountDigestView`) actually operates on. Unlike
    /// `digests(accountIds:role:recentLimit:db:)`'s `recentLimit`-capped
    /// preview, this fetches every matching thread so a bulk action
    /// (archive/delete/…) touches everything the row's own count badge
    /// promised, not just the couple shown as preview lines.
    public static func allSummaries(accountId: String, role: MailboxRoleRecord = .inbox, db: Database) throws -> [ThreadSummary] {
        let threads = try ThreadQuery.unifiedInboxRequest(accountIds: [accountId], role: role).fetchAll(db)
        return try ThreadQuery.summaries(forThreads: threads, db: db)
    }
}
