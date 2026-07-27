import Foundation
import GRDB

/// Query helpers for `MessageRecord`, shared between one-shot fetches and
/// `ValueObservation`-driven live lists (`MessageListView`'s data source).
public enum MessageQuery {
    /// Messages in one mailbox, newest first. Sorted by `internalDate`
    /// (the server's receipt time — always present and monotonic with
    /// arrival) rather than the sender-supplied `date` header, which can be
    /// missing or backdated.
    public static func request(mailboxId: Int64) -> QueryInterfaceRequest<MessageRecord> {
        MessageRecord
            .filter(Column("mailboxId") == mailboxId)
            .order(Column("internalDate").desc, Column("uid").desc)
    }

    /// A `ValueObservation` that re-fetches ``request(mailboxId:)`` whenever
    /// the `message` table changes, for `MessageListView` to observe.
    public static func observation(mailboxId: Int64) -> ValueObservation<ValueReducers.Fetch<[MessageRecord]>> {
        ValueObservation.tracking { db in
            try request(mailboxId: mailboxId).fetchAll(db)
        }
    }

    /// The single highest UID currently stored for a mailbox, used by
    /// `AccountSyncer` to resume an incremental sync (`UID FETCH
    /// uidNext:*`, M3). `nil` for an empty (or never-synced) mailbox.
    public static func maxUID(mailboxId: Int64, db: Database) throws -> UInt32? {
        let value = try Int64.fetchOne(
            db,
            sql: "SELECT MAX(uid) FROM message WHERE mailboxId = ?",
            arguments: [mailboxId]
        )
        guard let value else { return nil }
        return UInt32(value)
    }

    // MARK: - Unread counts (M10: sidebar badges)

    /// `\Seen` bit of `MessageFlags`, inlined as a raw SQL literal — matches
    /// `OtegamiCore.MessageFlags.seen.rawValue` (`1 << 0`). Kept here (not a
    /// dependency on `OtegamiCore.MessageFlags` from inside a SQL string)
    /// since a bitmask literal in SQL needs to be a compile-time constant
    /// either way; a unit test (`MessageQueryTests`) pins this value against
    /// the real `MessageFlags.seen.rawValue` so the two can't silently drift.
    static let seenFlagBit = 1

    /// Unread message counts per mailbox, for every mailbox belonging to
    /// `accountId` — one grouped query instead of one `COUNT(*)` per mailbox
    /// row, backed by `message_on_mailboxId_flagsRaw` (v9). Mailboxes with
    /// zero unread messages are simply absent from the result (not present
    /// with a `0`); callers should treat a missing key as zero.
    public static func unreadCounts(accountId: String, db: Database) throws -> [Int64: Int] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT message.mailboxId AS mailboxId, COUNT(*) AS unreadCount
                FROM message
                JOIN mailbox ON mailbox.id = message.mailboxId
                WHERE mailbox.accountId = ? AND message.flagsRaw & \(seenFlagBit) = 0
                GROUP BY message.mailboxId
                """,
            arguments: [accountId]
        )
        var counts: [Int64: Int] = [:]
        for row in rows {
            counts[row["mailboxId"] as Int64] = row["unreadCount"] as Int
        }
        return counts
    }

    public static func unreadCountsObservation(accountId: String) -> ValueObservation<ValueReducers.Fetch<[Int64: Int]>> {
        ValueObservation.tracking { db in try unreadCounts(accountId: accountId, db: db) }
    }

    /// Total unread count across every inbox-role mailbox of `accountIds` —
    /// the badge for "すべての受信トレイ" (the unified inbox sidebar row),
    /// scoped the same way `ThreadQuery.unifiedInboxRequest` scopes its
    /// thread list (inbox-role mailboxes only, not every mailbox).
    public static func unifiedInboxUnreadCount(accountIds: [String], db: Database) throws -> Int {
        guard !accountIds.isEmpty else { return 0 }
        let placeholders = accountIds.map { _ in "?" }.joined(separator: ",")
        var arguments: [(any DatabaseValueConvertible)?] = [MailboxRoleRecord.inbox.rawValue]
        arguments.append(contentsOf: accountIds)
        return try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM message
                JOIN mailbox ON mailbox.id = message.mailboxId
                WHERE mailbox.role = ? AND mailbox.accountId IN (\(placeholders)) AND message.flagsRaw & \(seenFlagBit) = 0
                      AND mailbox.isHidden = 0
                """,
            arguments: StatementArguments(arguments)
        ) ?? 0
    }

    public static func unifiedInboxUnreadCountObservation(accountIds: [String]) -> ValueObservation<ValueReducers.Fetch<Int>> {
        ValueObservation.tracking { db in try unifiedInboxUnreadCount(accountIds: accountIds, db: db) }
    }
}

/// Query helpers for `MailboxRecord`.
public enum MailboxQuery {
    /// All mailboxes for one account, ordered for sidebar display: Inbox
    /// first, then other special-use roles, then everything else
    /// alphabetically by display path.
    ///
    /// `includeHidden` (メールボックス単位の非表示): `false` filters out
    /// `MailboxRecord.isHidden` mailboxes — what the hamburger/sidebar tree
    /// (`SidebarView`/`FolderListSheet`) and the mac ⌘]/⌘[ mailbox cycling
    /// (`OtegamiApp.cycleMailboxSelection`) pass, so a hidden mailbox is
    /// simply absent from every navigation surface. Defaults to `true`
    /// (every existing caller before this feature keeps seeing every
    /// mailbox) — the per-account "メールボックスの表示設定" screen
    /// (`MailboxVisibilityView`) needs the unfiltered list to offer a
    /// toggle for *every* mailbox, hidden or not.
    public static func request(accountId: String, includeHidden: Bool = true) -> QueryInterfaceRequest<MailboxRecord> {
        var request = MailboxRecord.filter(Column("accountId") == accountId)
        if !includeHidden {
            request = request.filter(Column("isHidden") == false)
        }
        return request.order(
            (Column("role") == MailboxRoleRecord.inbox.rawValue).desc,
            Column("displayPath")
        )
    }

    public static func observation(accountId: String, includeHidden: Bool = true) -> ValueObservation<ValueReducers.Fetch<[MailboxRecord]>> {
        ValueObservation.tracking { db in
            try request(accountId: accountId, includeHidden: includeHidden).fetchAll(db)
        }
    }

    /// Flips `MailboxRecord.isHidden` — `MailboxVisibilityView`'s Toggle
    /// action. A targeted `UPDATE` (not a fetch-mutate-`update()` round
    /// trip) since the caller only ever has a mailbox id and the new value
    /// in hand, not a full `MailboxRecord`.
    public static func setHidden(mailboxId: Int64, hidden: Bool, db: Database) throws {
        try db.execute(
            sql: "UPDATE mailbox SET isHidden = ? WHERE id = ?",
            arguments: [hidden, mailboxId]
        )
    }

    /// Every mailbox (across `accountIds`) currently recording a sync
    /// failure (`MailboxRecord.lastSyncError` non-`nil`) — the query
    /// `MailboxSyncFailuresView`'s sidebar banner and the sidebar's own
    /// failure-count badge both observe. Ordered oldest-failure-first, the
    /// same convention `OpQueueQuery.failedOps` uses for its `createdAt`
    /// ordering (oldest problem surfaces first, rather than reshuffling
    /// every time a new failure is recorded).
    public static func syncFailures(accountIds: [String], db: Database) throws -> [MailboxRecord] {
        try MailboxRecord
            .filter(accountIds.contains(Column("accountId")))
            .filter(Column("lastSyncError") != nil)
            .order(Column("lastSyncErrorAt"))
            .fetchAll(db)
    }

    public static func syncFailuresObservation(accountIds: [String]) -> ValueObservation<ValueReducers.Fetch<[MailboxRecord]>> {
        ValueObservation.tracking { db in try syncFailures(accountIds: accountIds, db: db) }
    }
}
