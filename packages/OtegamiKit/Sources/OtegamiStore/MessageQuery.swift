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

    /// Total unread count across every `role`-role mailbox of `accountIds` —
    /// the badge for "すべての受信トレイ" (`role == .inbox`, the default), and
    /// 画面構造改修バッチ (Task #33, 3) の「横断ビュー」row's own unread badge
    /// for any other role, scoped the same way `ThreadQuery
    /// .unifiedInboxRequest` scopes its thread list (`role`-role mailboxes
    /// only, not every mailbox).
    public static func unifiedInboxUnreadCount(accountIds: [String], role: MailboxRoleRecord = .inbox, db: Database) throws -> Int {
        guard !accountIds.isEmpty else { return 0 }
        let placeholders = accountIds.map { _ in "?" }.joined(separator: ",")
        var arguments: [(any DatabaseValueConvertible)?] = [role.rawValue]
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

    public static func unifiedInboxUnreadCountObservation(accountIds: [String], role: MailboxRoleRecord = .inbox) -> ValueObservation<ValueReducers.Fetch<Int>> {
        ValueObservation.tracking { db in try unifiedInboxUnreadCount(accountIds: accountIds, role: role, db: db) }
    }

    // MARK: - Background body prefetch (launch/foreground)

    /// Up to `limit` of the unified inbox's most-recently-received messages
    /// that haven't had their body fetched yet, newest first across every
    /// account in `accountIds` — the candidate list for `SyncCoordinator
    /// .prefetchUnifiedInboxBodiesIfNeeded(accounts:now:authProvider:)`'s
    /// launch/foreground background body prefetch (the fix for "さっき読んだ
    /// メールも、アプリを起動し直すと読み込みが入る?表示まで時間がかかる" — a
    /// message that's near the top of the unified inbox but whose body was
    /// never lazily fetched pays a network round trip the moment it's
    /// opened; prefetching these ahead of time on launch/foreground means
    /// `MessageView.load()` usually finds `bodyState == .fetched` already).
    /// Mirrors `ThreadQuery.unifiedInboxFlatSummaries`'s join shape
    /// (inbox-role mailboxes, `isHidden = 0`) but filters on `message
    /// .bodyState = 'notFetched'` instead of read/unread, and returns
    /// `mailbox.path` (the raw IMAP path a session needs to `SELECT`)
    /// rather than a UI-facing `ThreadSummary`.
    public static func unfetchedUnifiedInboxCandidates(
        accountIds: [String],
        limit: Int,
        db: Database
    ) throws -> [UnifiedInboxPrefetchCandidate] {
        guard !accountIds.isEmpty else { return [] }
        let placeholders = accountIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT message.*, mailbox.accountId AS accountId, mailbox.path AS mailboxPath
            FROM message
            JOIN mailbox ON mailbox.id = message.mailboxId
            WHERE mailbox.role = ? AND mailbox.accountId IN (\(placeholders)) AND mailbox.isHidden = 0
                  AND message.bodyState = ?
            ORDER BY COALESCE(message.date, message.internalDate) DESC, message.uid DESC
            LIMIT ?
            """
        var arguments: [(any DatabaseValueConvertible)?] = [MailboxRoleRecord.inbox.rawValue]
        arguments.append(contentsOf: accountIds)
        arguments.append(MessageBodyState.notFetched.rawValue)
        arguments.append(limit)
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        return try rows.map { row in
            let message = try MessageRecord(row: row)
            let accountId: String = row["accountId"]
            let mailboxPath: String = row["mailboxPath"]
            return UnifiedInboxPrefetchCandidate(message: message, accountId: accountId, mailboxPath: mailboxPath)
        }
    }
}

/// One row of ``MessageQuery/unfetchedUnifiedInboxCandidates(accountIds:limit:db:)``
/// — carries `accountId`/`mailboxPath` alongside the `MessageRecord` itself
/// so a caller opening a per-account IMAP session (the launch/foreground
/// background body prefetch) doesn't have to re-look either up.
public struct UnifiedInboxPrefetchCandidate: Sendable, Equatable {
    public let message: MessageRecord
    public let accountId: String
    public let mailboxPath: String

    public init(message: MessageRecord, accountId: String, mailboxPath: String) {
        self.message = message
        self.accountId = accountId
        self.mailboxPath = mailboxPath
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
