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

    public var id: Int64 { thread.id ?? 0 }

    public init(thread: ThreadRecord, latestMessage: MessageRecord?) {
        self.thread = thread
        self.latestMessage = latestMessage
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
            ORDER BY thread.lastMessageDate DESC, thread.id DESC
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
            ORDER BY thread.lastMessageDate DESC, thread.id DESC
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
