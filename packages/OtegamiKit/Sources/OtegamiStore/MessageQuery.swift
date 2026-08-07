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
    ///
    /// `AND uid > 0` (Task #120): excludes a `MessageRecord.isPendingRelocation`
    /// row — its synthetic negative placeholder UID must never factor into
    /// "what's the highest *real* UID this mailbox has ever fetched," and
    /// `UInt32(value)` below would trap outright if a pending row's negative
    /// UID ever became the `MAX(uid)` (e.g. a mailbox containing nothing but
    /// a just-relocated pending message).
    public static func maxUID(mailboxId: Int64, db: Database) throws -> UInt32? {
        let value = try Int64.fetchOne(
            db,
            sql: "SELECT MAX(uid) FROM message WHERE mailboxId = ? AND uid > 0",
            arguments: [mailboxId]
        )
        guard let value else { return nil }
        return UInt32(value)
    }

    /// 古いメールのバックフィル同期: the lowest UID currently stored locally
    /// for this mailbox — `nil` for an empty mailbox (or one with only
    /// `MessageRecord.isPendingRelocation` placeholder rows, same `uid > 0`
    /// exclusion `maxUID` above uses and for the same reason). This is
    /// exactly the boundary `BackfillSyncer.resetCursor(mailboxId:db:)`
    /// (re)derives `mailbox.backfillLowerBound` from after a full-window
    /// fetch (initial sync, or a uidValidity-changed resync) — "everything
    /// below the oldest message we currently have locally is unscanned".
    public static func minUID(mailboxId: Int64, db: Database) throws -> UInt32? {
        let value = try Int64.fetchOne(
            db,
            sql: "SELECT MIN(uid) FROM message WHERE mailboxId = ? AND uid > 0",
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
    /// Task #52 追記: Gmail の All Mail (role `.all`) の未読数も
    /// `GmailArchiveFilter`のアーカイブ定義でフィルタする —
    /// `folderSheet.mailbox.<accountId>.<path>.unreadBadge`(All Mail の行の
    /// バッジ)が、実際にその行をタップして開いた時のスレッド一覧
    /// (`ThreadQuery.request(mailboxId:)`, 同じ定義でフィルタ済み)と矛盾しない
    /// ようにするため。Gmail の All Mail 以外のどのメールボックスにも
    /// 影響しない。
    public static func unreadCounts(accountId: String, db: Database) throws -> [Int64: Int] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT message.mailboxId AS mailboxId, COUNT(*) AS unreadCount
                FROM message
                JOIN mailbox ON mailbox.id = message.mailboxId
                JOIN account ON account.id = mailbox.accountId
                WHERE mailbox.accountId = ? AND message.flagsRaw & \(seenFlagBit) = 0
                      AND \(GmailArchiveFilter.excludeUnarchivedSQL)
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

    /// One mailbox's unread count, out of ``unreadCounts(accountId:db:)``'s
    /// per-account grouped result — for a caller that only cares about a
    /// single mailbox (e.g. `MessageListView`'s header unread badge for a
    /// `.mailbox` selection, ヘッダ件数表示のメッセージ単位未読数化) and
    /// would otherwise have to inline the same "missing key means zero"
    /// lookup itself. Still one grouped query under the hood, not a
    /// per-mailbox `COUNT(*)` — cheap enough that a caller observing one
    /// mailbox doesn't need its own narrower SQL.
    public static func unreadCount(mailboxId: Int64, accountId: String, db: Database) throws -> Int {
        try unreadCounts(accountId: accountId, db: db)[mailboxId] ?? 0
    }

    public static func unreadCountObservation(mailboxId: Int64, accountId: String) -> ValueObservation<ValueReducers.Fetch<Int>> {
        ValueObservation.tracking { db in try unreadCount(mailboxId: mailboxId, accountId: accountId, db: db) }
    }

    /// Total unread count across every `role`-role mailbox of `accountIds` —
    /// the badge for "すべての受信トレイ" (`role == .inbox`, the default), and
    /// 画面構造改修バッチ (Task #33, 3) の「横断ビュー」row's own unread badge
    /// for any other role, scoped the same way `ThreadQuery
    /// .unifiedInboxRequest` scopes its thread list (`role`-role mailboxes
    /// only, not every mailbox).
    /// `account.kind`をJOINして参照するのは Gmail のアーカイブマッピング
    /// (`MailboxRoleRecord.gmailArchiveQueryRole`, Task #52, 2) のため —
    /// `ThreadQuery.unifiedInboxRequest`と同じ理由・同じ出し分け方。
    /// `role == .all`の非Gmail特別扱い (Task #141、「すべてのメール」は
    /// 非Gmailアカウントで role 一致を要求しない) も同関数と同じ —
    /// その doc comment参照。
    public static func unifiedInboxUnreadCount(accountIds: [String], role: MailboxRoleRecord = .inbox, db: Database) throws -> Int {
        guard !accountIds.isEmpty else { return 0 }
        let placeholders = accountIds.map { _ in "?" }.joined(separator: ",")
        let nonGmailMatchesAnyMailbox = role == .all
        let nonGmailCondition = nonGmailMatchesAnyMailbox
            ? "account.kind != ?"
            : "(account.kind != ? AND mailbox.role = ?)"
        var arguments: [(any DatabaseValueConvertible)?] = [AccountKind.gmail.rawValue, role.gmailArchiveQueryRole.rawValue, AccountKind.gmail.rawValue]
        if !nonGmailMatchesAnyMailbox {
            arguments.append(role.rawValue)
        }
        arguments.append(contentsOf: accountIds)
        return try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM message
                JOIN mailbox ON mailbox.id = message.mailboxId
                JOIN account ON account.id = mailbox.accountId
                WHERE (
                          (account.kind = ? AND mailbox.role = ?)
                          OR \(nonGmailCondition)
                      )
                      AND mailbox.accountId IN (\(placeholders)) AND message.flagsRaw & \(seenFlagBit) = 0
                      AND mailbox.isHidden = 0
                      AND \(GmailArchiveFilter.excludeUnarchivedSQL)
                """,
            arguments: StatementArguments(arguments)
        ) ?? 0
    }

    public static func unifiedInboxUnreadCountObservation(accountIds: [String], role: MailboxRoleRecord = .inbox) -> ValueObservation<ValueReducers.Fetch<Int>> {
        ValueObservation.tracking { db in try unifiedInboxUnreadCount(accountIds: accountIds, role: role, db: db) }
    }

    // MARK: - Background body prefetch (launch/foreground/post-sync)

    /// Up to `limit` of the unified inbox's not-yet-fetched messages
    /// received within `since`, newest first across every account in
    /// `accountIds` — the candidate list for `SyncCoordinator`'s background
    /// body prefetch (launch/foreground, and after each mailbox sync
    /// completes; Task #63). Originally (Task #31) this was simply "the
    /// most recent `limit` not-yet-fetched messages" — the fix for "さっき
    /// 読んだメールも、アプリを起動し直すと読み込みが入る?表示まで時間が
    /// かかる". Task #63 changed the primary selection criterion to a
    /// **recency window** ("直近3日間くらいのものでいい") instead of a raw
    /// count: a quiet inbox with only 5 messages in the last 3 days
    /// shouldn't also drag in a 6-day-old message #6 just to fill a count
    /// of 30, and a noisy inbox with 300 messages in the last 3 days
    /// shouldn't fetch all 300 in one pass either — `limit` remains as a
    /// safety cap on top of the window, not the primary criterion anymore.
    /// Mirrors `ThreadQuery.unifiedInboxFlatSummaries`'s join shape
    /// (inbox-role mailboxes, `isHidden = 0`) but filters on `message
    /// .bodyState = 'notFetched'` instead of read/unread, and returns
    /// `mailbox.path` (the raw IMAP path a session needs to `SELECT`)
    /// rather than a UI-facing `ThreadSummary`.
    ///
    /// The `since` cutoff is applied to the same `COALESCE(message.date,
    /// message.internalDate)` expression used for the `ORDER BY` below
    /// (rather than `internalDate` alone, which is what
    /// ``request(mailboxId:)`` uses) so a message's presence/absence in the
    /// result is consistent with where it would sort — using a different
    /// field for the cutoff than for the ordering could otherwise exclude a
    /// message that sorts within the window, or include one that doesn't.
    public static func unfetchedUnifiedInboxCandidates(
        accountIds: [String],
        since: Date,
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
                  AND COALESCE(message.date, message.internalDate) >= ?
            ORDER BY COALESCE(message.date, message.internalDate) DESC, message.uid DESC
            LIMIT ?
            """
        var arguments: [(any DatabaseValueConvertible)?] = [MailboxRoleRecord.inbox.rawValue]
        arguments.append(contentsOf: accountIds)
        arguments.append(MessageBodyState.notFetched.rawValue)
        arguments.append(since)
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

/// One row of ``MessageQuery/unfetchedUnifiedInboxCandidates(accountIds:since:limit:db:)``
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

    /// The mailbox paths a `.unifiedRole(role)` view's pull-to-refresh should
    /// sync for one account — the sync-side mirror of the display-side scope
    /// `ThreadQuery.unifiedInboxRequest` defines, and it must be changed
    /// together with it:
    /// - Gmail: `role.gmailArchiveQueryRole` — `.archive` → All Mail
    ///   (`.all`), every other role unchanged. Without this mapping a Gmail
    ///   account matched nothing for `.archive` (its All Mail mailbox has
    ///   role `.all`, not `.archive`), so `MessageListView`'s caller fell
    ///   back to syncing *every* mailbox on the account — dozens of labels
    ///   on a typical Gmail account — while the list on screen was reading
    ///   from All Mail all along.
    /// - Non-Gmail with `role == .all`: every non-hidden mailbox, matching
    ///   Task #141's definition of 「すべてのメール」for providers that have
    ///   no `\All` folder at all.
    /// - Otherwise: an exact `role` match.
    ///
    /// Hidden mailboxes (`MailboxRecord.isHidden`) are excluded throughout,
    /// as they are in the display query. A `Set` rather than a single path
    /// because one account can have several mailboxes matching a role (Task
    /// #119's name-inference fallback mis-detecting one); an empty result
    /// means "nothing known for this role yet", which the caller treats as
    /// its own self-healing fallback.
    public static func roleScopedMailboxPaths(
        accountId: String, accountKind: AccountKind, role: MailboxRoleRecord, db: Database
    ) throws -> Set<String> {
        var request = MailboxRecord
            .filter(Column("accountId") == accountId)
            .filter(Column("isHidden") == false)
        if accountKind == .gmail {
            request = request.filter(Column("role") == role.gmailArchiveQueryRole.rawValue)
        } else if role != .all {
            request = request.filter(Column("role") == role.rawValue)
        }
        return Set(try request.fetchAll(db).map(\.path))
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
