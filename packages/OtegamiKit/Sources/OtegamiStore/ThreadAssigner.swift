import Foundation
import GRDB
import OtegamiCore

/// The DB-applying half of M4's threading pass: builds `Threader
/// .ExistingThreadContext` from the local database, calls `Threader.decide`,
/// and writes the result back (`message.threadId`, `thread` rows, and the
/// `thread.messageCount`/`unreadCount`/`lastMessageDate` aggregates the plan
/// calls out as app-logic-maintained rather than trigger-maintained).
///
/// Every function here takes an already-open `Database` and is meant to run
/// inside the same write transaction as whatever mutated `message` in the
/// first place (`AccountSyncer.upsert`, a flag toggle, a delete) — so a
/// crash mid-sync never leaves a message upserted but unthreaded, or a
/// thread's aggregate stale relative to its messages.
public enum ThreadAssigner {
    /// Threads (or re-threads) one message, given it's already been
    /// inserted/updated (and its `messageReference` rows already replaced,
    /// for a resync). Call this once per message after
    /// `AccountSyncer.upsert`-style persistence completes for it.
    ///
    /// Safe to call on an already-threaded message too (e.g. from the bulk
    /// backfill pass re-walking every unthreaded message in date order) —
    /// in that case it's the caller's job to skip messages that don't need
    /// re-deciding; this function always re-runs `Threader.decide` and
    /// applies whatever it returns.
    @discardableResult
    public static func assignThread(messageId: Int64, accountId: String, db: Database) throws -> Int64? {
        guard var message = try MessageRecord.fetchOne(db, key: messageId) else { return nil }

        let references = try MessageReferenceRecord
            .filter(Column("messageId") == messageId)
            .order(Column("position"))
            .fetchAll(db)
            .map(\.referenceValue)

        let facts = Threader.MessageFacts(
            id: messageId,
            messageId: message.messageId,
            inReplyTo: message.inReplyTo,
            references: references,
            normalizedSubject: message.normalizedSubject,
            participants: participants(of: message),
            date: message.date ?? message.internalDate,
            gmailThreadId: message.gmailThreadId
        )

        let context = try buildContext(for: facts, accountId: accountId, excludingMessageId: messageId, db: db)
        let decision = Threader.decide(for: facts, context: context)

        switch decision {
        case .join(let threadId):
            message.threadId = threadId
            try message.update(db, columns: [Column("threadId")])
            try recomputeAggregates(threadId: threadId, db: db)
            return threadId

        case .joinAndMerge(let threadId, let mergedThreadIds):
            for mergedId in mergedThreadIds {
                try db.execute(
                    sql: "UPDATE message SET threadId = ? WHERE threadId = ?",
                    arguments: [threadId, mergedId]
                )
            }
            message.threadId = threadId
            try message.update(db, columns: [Column("threadId")])
            try ThreadRecord.filter(mergedThreadIds.contains(Column("id"))).deleteAll(db)
            try recomputeAggregates(threadId: threadId, db: db)
            return threadId

        case .createNew:
            var thread = ThreadRecord(
                accountId: accountId,
                normalizedSubject: message.normalizedSubject,
                lastMessageDate: facts.date,
                messageCount: 0,
                unreadCount: 0
            )
            try thread.insert(db)
            guard let newThreadId = thread.id else { return nil }
            message.threadId = newThreadId
            try message.update(db, columns: [Column("threadId")])
            try recomputeAggregates(threadId: newThreadId, db: db)
            return newThreadId
        }
    }

    /// Bulk (re)threading for one account: every message with `threadId ==
    /// nil` (never threaded — a freshly-synced message, or a pre-M4 row
    /// migrated in with a null `threadId`), processed oldest-first so a
    /// reply is always folded in after the message it references. Self-
    /// healing for out-of-order sync (e.g. a Sent-mailbox reply upserted
    /// before the Inbox original it replies to): a message whose
    /// references don't resolve yet just starts its own thread, and a
    /// *later* bulk pass (or a later `assignThread` call once the original
    /// arrives) merges them via `Threader`'s bridging-message case.
    ///
    /// Called after `AccountSyncer.performInitialSync` finishes every
    /// mailbox, and once at app startup per existing account (`AppEnvironment`)
    /// to backfill accounts synced before M4 shipped, whose `message.threadId`
    /// is still `nil` for every row.
    public static func assignAllUnthreaded(accountId: String, db: Database) throws {
        let unthreaded = try MessageRecord.fetchAll(
            db,
            sql: """
            SELECT message.* FROM message
            JOIN mailbox ON mailbox.id = message.mailboxId
            WHERE mailbox.accountId = ? AND message.threadId IS NULL
            ORDER BY COALESCE(message.date, message.internalDate) ASC, message.id ASC
            """,
            arguments: [accountId]
        )
        for message in unthreaded {
            guard let messageId = message.id else { continue }
            // Re-fetch is unnecessary (we already have the row), but
            // `assignThread` is the single source of truth for the
            // decide-and-apply sequence, so route through it rather than
            // duplicating that logic here.
            _ = try assignThread(messageId: messageId, accountId: accountId, db: db)
        }
    }

    /// Recomputes `messageCount`/`unreadCount`/`lastMessageDate` for
    /// `threadId` from its current member messages, or deletes the thread
    /// row outright if it no longer has any (the last message in it was
    /// deleted, or every message got reparented away by a merge). Call
    /// after any mutation that could change a thread's membership or a
    /// member's `\Seen` flag: message insert/re-thread (handled internally
    /// by `assignThread`), flag toggle, and message deletion.
    public static func recomputeAggregates(threadId: Int64, db: Database) throws {
        let messages = try MessageRecord.filter(Column("threadId") == threadId).fetchAll(db)
        guard !messages.isEmpty else {
            try ThreadRecord.deleteOne(db, key: threadId)
            return
        }
        guard var thread = try ThreadRecord.fetchOne(db, key: threadId) else { return }
        thread.messageCount = messages.count
        thread.unreadCount = messages.filter { !$0.flags.contains(.seen) }.count
        thread.lastMessageDate = messages.compactMap { $0.date ?? $0.internalDate }.max()
        try thread.update(db)
    }

    /// Recomputes aggregates for every distinct thread represented among
    /// `messages` — a convenience for callers (deletion paths) that just
    /// deleted a batch of messages and need to settle every thread that
    /// batch touched, some of which might now be empty.
    public static func recomputeAggregates(forThreadsAmong messages: [MessageRecord], db: Database) throws {
        for threadId in Set(messages.compactMap(\.threadId)) {
            try recomputeAggregates(threadId: threadId, db: db)
        }
    }

    // MARK: - Context building

    private static func participants(of message: MessageRecord) -> Set<String> {
        Set((message.fromAddresses + message.toAddresses + message.ccAddresses).map { $0.address.lowercased() })
    }

    private static func buildContext(
        for facts: Threader.MessageFacts,
        accountId: String,
        excludingMessageId: Int64,
        db: Database
    ) throws -> Threader.ExistingThreadContext {
        var referencedIds = facts.references
        if let inReplyTo = facts.inReplyTo, !referencedIds.contains(inReplyTo) {
            referencedIds.append(inReplyTo)
        }

        var threadIdByMessageId: [String: Int64] = [:]
        var threadMessageCounts: [Int64: Int] = [:]

        if !referencedIds.isEmpty {
            var args: [(any DatabaseValueConvertible)?] = [accountId, excludingMessageId]
            args.append(contentsOf: referencedIds)
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT message.messageId AS ref, message.threadId AS threadId
                FROM message
                JOIN mailbox ON mailbox.id = message.mailboxId
                WHERE mailbox.accountId = ?
                  AND message.id != ?
                  AND message.threadId IS NOT NULL
                  AND message.messageId IN (\(referencedIds.map { _ in "?" }.joined(separator: ",")))
                """,
                arguments: StatementArguments(args)
            )
            for row in rows {
                let ref: String? = row["ref"]
                let threadId: Int64? = row["threadId"]
                guard let ref, let threadId else { continue }
                threadIdByMessageId[ref] = threadId
            }
        }

        var threadIdByGmailThreadId: [Int64: Int64] = [:]
        if let gmailThreadId = facts.gmailThreadId {
            let existing = try Int64.fetchOne(
                db,
                sql: """
                SELECT message.threadId FROM message
                JOIN mailbox ON mailbox.id = message.mailboxId
                WHERE mailbox.accountId = ? AND message.id != ? AND message.gmailThreadId = ? AND message.threadId IS NOT NULL
                LIMIT 1
                """,
                arguments: [accountId, excludingMessageId, gmailThreadId]
            )
            if let existing {
                threadIdByGmailThreadId[gmailThreadId] = existing
            }
        }

        var subjectCandidatesByNormalizedSubject: [String: [Threader.SubjectCandidate]] = [:]
        if let subject = facts.normalizedSubject, !subject.isEmpty {
            let rows = try MessageRecord.fetchAll(
                db,
                sql: """
                SELECT message.* FROM message
                JOIN mailbox ON mailbox.id = message.mailboxId
                WHERE mailbox.accountId = ? AND message.id != ? AND message.normalizedSubject = ? AND message.threadId IS NOT NULL
                """,
                arguments: [accountId, excludingMessageId, subject]
            )
            var byThread: [Int64: (participants: Set<String>, date: Date)] = [:]
            for row in rows {
                guard let threadId = row.threadId else { continue }
                let rowParticipants = participants(of: row)
                let rowDate = row.date ?? row.internalDate
                if var existing = byThread[threadId] {
                    existing.participants.formUnion(rowParticipants)
                    existing.date = max(existing.date, rowDate)
                    byThread[threadId] = existing
                } else {
                    byThread[threadId] = (rowParticipants, rowDate)
                }
            }
            subjectCandidatesByNormalizedSubject[subject] = byThread.map { threadId, value in
                Threader.SubjectCandidate(threadId: threadId, participants: value.participants, date: value.date)
            }
            // The candidate threads' current member counts also feed
            // `threadMessageCounts` — harmless overlap with the
            // References-derived counts above (a thread found by both
            // paths just gets its count written twice, same value).
            for threadId in byThread.keys where threadMessageCounts[threadId] == nil {
                threadMessageCounts[threadId] = try MessageRecord.filter(Column("threadId") == threadId).fetchCount(db)
            }
        }

        for threadId in Set(threadIdByMessageId.values) where threadMessageCounts[threadId] == nil {
            threadMessageCounts[threadId] = try MessageRecord.filter(Column("threadId") == threadId).fetchCount(db)
        }

        return Threader.ExistingThreadContext(
            threadIdByMessageId: threadIdByMessageId,
            threadIdByGmailThreadId: threadIdByGmailThreadId,
            threadMessageCounts: threadMessageCounts,
            subjectCandidatesByNormalizedSubject: subjectCandidatesByNormalizedSubject
        )
    }
}
