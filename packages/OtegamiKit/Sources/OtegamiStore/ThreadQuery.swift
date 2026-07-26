import Foundation
import GRDB
import OtegamiCore

/// One thread plus its most recent message's display-relevant fields —
/// what `ThreadRow` (M4's per-thread message-list row: participants,
/// subject, snippet, count badge, unread dot, latest date) needs without a
/// separate query per row. `ThreadRecord` alone only has
/// `messageCount`/`unreadCount`/`lastMessageDate`/`normalizedSubject`; the
/// sender/snippet/original (non-normalized) subject only exist per-message.
public struct ThreadSummary: Sendable, Equatable, Identifiable {
    public var thread: ThreadRecord
    /// The newest message in the thread (by `internalDate`, tie-broken by
    /// `uid`). `nil` only transiently — a thread with zero messages is
    /// deleted by `ThreadAssigner.recomputeAggregates`, so this shouldn't
    /// normally be `nil` for a thread a query actually returned.
    public var latestMessage: MessageRecord?

    /// B3 フラット表示: non-`nil` only for a synthetic, single-message
    /// "thread" built by `flatSummaries`/`unifiedInboxFlatSummaries` below —
    /// see `init(flatMessage:accountId:)`. Distinct from `thread.id`
    /// because flat mode can legitimately show *several* rows sharing the
    /// same real `thread.id` (every message of a multi-message thread gets
    /// its own row), and `List`/`ForEach` identity requires each row's `id`
    /// to be unique — `thread.id` alone would collide across those rows.
    private var flatMessageId: Int64?

    public var id: Int64 { flatMessageId ?? (thread.id ?? 0) }

    public init(thread: ThreadRecord, latestMessage: MessageRecord?) {
        self.thread = thread
        self.latestMessage = latestMessage
        self.flatMessageId = nil
    }

    /// B3: wraps one message as a "thread of one" for flat-mode row
    /// rendering — `ThreadRowView`/`MessageListRow` read only `summary
    /// .thread.*`/`summary.latestMessage`/`summary.id`, so this needs no
    /// changes to either: `thread.messageCount = 1` keeps the ">1" count
    /// badge from appearing, `thread.unreadCount`/`isPinned` reflect this
    /// one message directly rather than a real aggregate, and `thread.id`
    /// is still the message's *real* `threadId` — swipe/tap actions
    /// (toggleRead/archive/delete/pin) deliberately keep operating on the
    /// whole underlying thread even from a flat row (see
    /// `MessageListView`'s flat-mode doc comment for why this was chosen
    /// over building a fully separate per-message action path).
    public init(flatMessage message: MessageRecord, accountId: String) {
        self.thread = ThreadRecord(
            id: message.threadId,
            accountId: accountId,
            normalizedSubject: message.normalizedSubject,
            lastMessageDate: message.date ?? message.internalDate,
            messageCount: 1,
            unreadCount: message.flags.contains(.seen) ? 0 : 1,
            isPinned: message.isPinnedLocal
        )
        self.latestMessage = message
        self.flatMessageId = message.id
    }
}

/// Query helpers for `ThreadRecord`/`ThreadSummary`, the M4 counterparts to
/// `MessageQuery`/`MailboxQuery`. `MessageListView` observes these instead
/// of raw `MessageRecord` rows once a mailbox has been threaded.
public enum ThreadQuery {
    /// Threads with at least one message in `mailboxId`, newest first.
    /// `thread.lastMessageDate` reflects the thread's newest message
    /// account-wide (a thread can span mailboxes, e.g. Inbox + Sent), which
    /// is also what this sorts by — matching how a label-based mail client
    /// like Gmail orders a folder's thread list.
    ///
    /// M10 rewrite (docs/performance.md): the original `SELECT DISTINCT
    /// thread.* ... JOIN message ...` had to join and de-duplicate every
    /// matching *message* row before it could sort/limit — at 100k-message
    /// scale that meant sorting effectively the whole mailbox even for a
    /// 50-row first page. An `EXISTS` membership check instead lets SQLite
    /// walk `thread` directly in `lastMessageDate` order (via
    /// `thread_on_lastMessageDate`, added in v9) and stop as soon as
    /// `limit` threads have passed the check — the per-thread `EXISTS`
    /// probe itself is an index lookup against `message_on_threadId_mailboxId`
    /// (also v9), not a scan. `limit` is `nil` (unlimited, matching the
    /// pre-M10 behavior) unless the caller opts into paging.
    public static func request(mailboxId: Int64, limit: Int? = nil) -> SQLRequest<ThreadRecord> {
        var sql = """
            SELECT thread.* FROM thread
            WHERE EXISTS (
                SELECT 1 FROM message WHERE message.threadId = thread.id AND message.mailboxId = ?
            )
            ORDER BY thread.isPinned DESC, thread.lastMessageDate DESC, thread.id DESC
            """
        var arguments: [(any DatabaseValueConvertible)?] = [mailboxId]
        if let limit {
            sql += " LIMIT ?"
            arguments.append(limit)
        }
        return SQLRequest(sql: sql, arguments: StatementArguments(arguments))
    }

    /// Threads with at least one message in an inbox-role mailbox across
    /// any of `accountIds` — the "すべての受信トレイ" unified inbox. Each
    /// thread still belongs to exactly one account (`thread.accountId`);
    /// this unions across accounts at query time rather than merging
    /// threads across account boundaries (plan: "アカウント境界を跨いだスレッド
    /// 結合はしない"). Same `EXISTS`-based rewrite as ``request(mailboxId:limit:)``
    /// and for the same reason — see its doc comment.
    public static func unifiedInboxRequest(accountIds: [String], limit: Int? = nil) -> SQLRequest<ThreadRecord> {
        guard !accountIds.isEmpty else {
            return SQLRequest(sql: "SELECT * FROM thread WHERE 0")
        }
        let placeholders = accountIds.map { _ in "?" }.joined(separator: ",")
        var sql = """
            SELECT thread.* FROM thread
            WHERE thread.accountId IN (\(placeholders))
              AND EXISTS (
                  SELECT 1 FROM message
                  JOIN mailbox ON mailbox.id = message.mailboxId
                  WHERE message.threadId = thread.id AND mailbox.role = ? AND mailbox.accountId = thread.accountId
              )
            ORDER BY thread.isPinned DESC, thread.lastMessageDate DESC, thread.id DESC
            """
        var arguments: [(any DatabaseValueConvertible)?] = accountIds
        arguments.append(MailboxRoleRecord.inbox.rawValue)
        if let limit {
            sql += " LIMIT ?"
            arguments.append(limit)
        }
        return SQLRequest(sql: sql, arguments: StatementArguments(arguments))
    }

    /// Attaches each thread's newest message, for `ThreadSummary`-driven
    /// row rendering. One extra indexed point-lookup per thread — fine at
    /// M4's scale; a single-query join could replace this later if it ever
    /// shows up in profiling.
    public static func summaries(forThreads threads: [ThreadRecord], db: Database) throws -> [ThreadSummary] {
        try threads.map { thread in
            guard let threadId = thread.id else { return ThreadSummary(thread: thread, latestMessage: nil) }
            let latest = try MessageRecord
                .filter(Column("threadId") == threadId)
                .order(Column("internalDate").desc, Column("uid").desc)
                .fetchOne(db)
            return ThreadSummary(thread: thread, latestMessage: latest)
        }
    }

    /// `limit` (M10 pagination — `MessageListView`'s "load more on scroll",
    /// docs/performance.md): `nil` keeps the pre-M10 "fetch everything"
    /// behavior for any caller that still wants it.
    public static func summariesObservation(mailboxId: Int64, limit: Int? = nil) -> ValueObservation<ValueReducers.Fetch<[ThreadSummary]>> {
        ValueObservation.tracking { db in
            try summaries(forThreads: request(mailboxId: mailboxId, limit: limit).fetchAll(db), db: db)
        }
    }

    public static func unifiedInboxSummariesObservation(accountIds: [String], limit: Int? = nil) -> ValueObservation<ValueReducers.Fetch<[ThreadSummary]>> {
        ValueObservation.tracking { db in
            try summaries(forThreads: unifiedInboxRequest(accountIds: accountIds, limit: limit).fetchAll(db), db: db)
        }
    }

    // MARK: - フラット表示 (B3)

    /// One row per *message* rather than per thread, for the "スレッドに
    /// まとめない" list-display setting — pinned messages first, then newest
    /// first, mirroring `request(mailboxId:limit:)`'s own ordering.
    /// `ThreadSummary(flatMessage:accountId:)` wraps each row so
    /// `ThreadRowView`/`MessageListRow`/`MessageListView`'s existing
    /// rendering and row actions need no changes to support this mode — see
    /// that initializer's doc comment.
    public static func flatSummaries(mailboxId: Int64, limit: Int? = nil, accountId: String, db: Database) throws -> [ThreadSummary] {
        var sql = """
            SELECT * FROM message
            WHERE mailboxId = ?
            ORDER BY isPinnedLocal DESC, COALESCE(date, internalDate) DESC, uid DESC
            """
        var arguments: [(any DatabaseValueConvertible)?] = [mailboxId]
        if let limit {
            sql += " LIMIT ?"
            arguments.append(limit)
        }
        let messages = try MessageRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        return messages.map { ThreadSummary(flatMessage: $0, accountId: accountId) }
    }

    public static func flatSummariesObservation(mailboxId: Int64, limit: Int? = nil, accountId: String) -> ValueObservation<ValueReducers.Fetch<[ThreadSummary]>> {
        ValueObservation.tracking { db in try flatSummaries(mailboxId: mailboxId, limit: limit, accountId: accountId, db: db) }
    }

    /// The flat-mode counterpart to `unifiedInboxRequest` — every account's
    /// inbox-role mailbox, interleaved. Needs `mailbox.accountId` per row
    /// (unlike the single-mailbox case above, where the caller already
    /// knows it), so this fetches plain `Row`s and decodes `MessageRecord`
    /// out of each one via its `FetchableRecord` conformance (GRDB's default
    /// `Decodable`-based decoding simply ignores the extra `accountId`
    /// column it doesn't declare a property for) rather than using
    /// `MessageRecord.fetchAll(db:sql:)` directly, which would only see the
    /// `message.*` columns.
    public static func unifiedInboxFlatSummaries(accountIds: [String], limit: Int? = nil, db: Database) throws -> [ThreadSummary] {
        guard !accountIds.isEmpty else { return [] }
        let placeholders = accountIds.map { _ in "?" }.joined(separator: ",")
        var sql = """
            SELECT message.*, mailbox.accountId AS accountId FROM message
            JOIN mailbox ON mailbox.id = message.mailboxId
            WHERE mailbox.role = ? AND mailbox.accountId IN (\(placeholders))
            ORDER BY message.isPinnedLocal DESC, COALESCE(message.date, message.internalDate) DESC, message.uid DESC
            """
        var arguments: [(any DatabaseValueConvertible)?] = [MailboxRoleRecord.inbox.rawValue]
        arguments.append(contentsOf: accountIds)
        if let limit {
            sql += " LIMIT ?"
            arguments.append(limit)
        }
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        return try rows.map { row in
            let message = try MessageRecord(row: row)
            let accountId: String = row["accountId"]
            return ThreadSummary(flatMessage: message, accountId: accountId)
        }
    }

    public static func unifiedInboxFlatSummariesObservation(accountIds: [String], limit: Int? = nil) -> ValueObservation<ValueReducers.Fetch<[ThreadSummary]>> {
        ValueObservation.tracking { db in try unifiedInboxFlatSummaries(accountIds: accountIds, limit: limit, db: db) }
    }

    /// Every message in `threadId`, oldest first — what `ThreadDetailView`
    /// lays out vertically, collapsing everything but the newest.
    public static func messages(threadId: Int64, db: Database) throws -> [MessageRecord] {
        try MessageRecord
            .filter(Column("threadId") == threadId)
            .order(Column("internalDate"), Column("uid"))
            .fetchAll(db)
    }

    public static func messagesObservation(threadId: Int64) -> ValueObservation<ValueReducers.Fetch<[MessageRecord]>> {
        ValueObservation.tracking { db in try messages(threadId: threadId, db: db) }
    }
}
