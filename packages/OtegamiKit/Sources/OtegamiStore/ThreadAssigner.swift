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
    /// Called after `AccountSyncer.performInitialSync`/`.performIncrementalSync`
    /// finish every mailbox, and once at app startup per existing account
    /// (`AppEnvironment`) to backfill accounts synced before M4 shipped,
    /// whose `message.threadId` is still `nil` for every row.
    ///
    /// This used to loop `assignThread` once per unthreaded message — clear,
    /// but ~7-8 SQL statements per message (`docs/performance.md`: 14
    /// seconds for a 20k-message backfill), since `Threader.decide`'s
    /// context and `recomputeAggregates`'s membership re-fetch both hit the
    /// database fresh every time. The batched version below computes the
    /// *entire* pass in memory first (`BatchThreader.plan`, calling
    /// `Threader.decide` in the exact same date order against a context
    /// that grows the same way, just backed by dictionaries instead of
    /// queries — see that type's doc comment for why the results are
    /// identical) and then applies it in a handful of bulk statements: one
    /// targeted preload query, one insert per new thread (grouping every
    /// new thread into a single multi-row statement isn't worth the
    /// complexity at this scale — see the type's tests for the count this
    /// was measured against), a couple of chunked bulk `UPDATE`s for
    /// reparenting/assigning `message.threadId`, and one chunked bulk
    /// aggregate recompute — instead of thousands of round trips.
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
        guard !unthreaded.isEmpty else { return }

        let messageRowIds = unthreaded.compactMap(\.id)
        let referencesByMessageId = try referenceTokens(forMessageIds: messageRowIds, db: db)

        let facts: [Threader.MessageFacts] = unthreaded.compactMap { message in
            guard let id = message.id else { return nil }
            return Threader.MessageFacts(
                id: id,
                messageId: message.messageId,
                inReplyTo: message.inReplyTo,
                references: referencesByMessageId[id] ?? [],
                normalizedSubject: message.normalizedSubject,
                participants: participants(of: message),
                date: message.date ?? message.internalDate,
                gmailThreadId: message.gmailThreadId
            )
        }

        var candidateMessageIds: Set<String> = []
        var candidateGmailThreadIds: Set<Int64> = []
        var candidateSubjects: Set<String> = []
        for message in facts {
            candidateMessageIds.formUnion(message.references)
            if let inReplyTo = message.inReplyTo { candidateMessageIds.insert(inReplyTo) }
            if let gmailThreadId = message.gmailThreadId { candidateGmailThreadIds.insert(gmailThreadId) }
            if let subject = message.normalizedSubject, !subject.isEmpty { candidateSubjects.insert(subject) }
        }

        let existingThreadedRows = try existingThreadedMatches(
            accountId: accountId,
            candidateMessageIds: candidateMessageIds,
            candidateGmailThreadIds: candidateGmailThreadIds,
            candidateSubjects: candidateSubjects,
            db: db
        )
        let existingThreadIds = Set(existingThreadedRows.compactMap(\.threadId))
        let existingCounts = try messageCounts(forThreadIds: existingThreadIds, db: db)
        let maxExistingThreadId = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM thread") ?? 0

        let existingMessages = existingThreadedRows.compactMap { message -> BatchThreader.ExistingMessage? in
            guard let threadId = message.threadId else { return nil }
            return BatchThreader.ExistingMessage(
                threadId: threadId,
                messageId: message.messageId,
                gmailThreadId: message.gmailThreadId,
                normalizedSubject: message.normalizedSubject,
                participants: participants(of: message),
                date: message.date ?? message.internalDate
            )
        }

        let plan = BatchThreader.plan(
            unthreadedMessages: facts,
            existingMessages: existingMessages,
            existingThreadMessageCounts: existingCounts,
            maxExistingThreadId: maxExistingThreadId
        )

        try apply(plan, accountId: accountId, db: db)
    }

    // MARK: - Batched assignAllUnthreaded: DB glue

    private static func referenceTokens(forMessageIds messageIds: [Int64], db: Database) throws -> [Int64: [String]] {
        guard !messageIds.isEmpty else { return [:] }
        var result: [Int64: [String]] = [:]
        for chunk in messageIds.chunked(into: 400) {
            let rows = try MessageReferenceRecord
                .filter(chunk.contains(Column("messageId")))
                .order(Column("messageId"), Column("position"))
                .fetchAll(db)
            for row in rows {
                result[row.messageId, default: []].append(row.referenceValue)
            }
        }
        return result
    }

    /// Already-threaded messages that some message in this batch could
    /// plausibly match against — narrowed to exactly the union of what
    /// every individual `Threader.decide` call in this batch would have
    /// looked up on its own (via `References`/`In-Reply-To` token,
    /// `gmailThreadId`, or `normalizedSubject`), so this stays proportional
    /// to *this batch's* fan-out rather than the account's whole history
    /// (`assignAllUnthreaded` runs after every incremental sync, almost
    /// always against a small-or-empty batch on top of a much larger
    /// already-threaded account — scanning the full history every time
    /// would trade one bottleneck for another).
    private static func existingThreadedMatches(
        accountId: String,
        candidateMessageIds: Set<String>,
        candidateGmailThreadIds: Set<Int64>,
        candidateSubjects: Set<String>,
        db: Database
    ) throws -> [MessageRecord] {
        guard !candidateMessageIds.isEmpty || !candidateGmailThreadIds.isEmpty || !candidateSubjects.isEmpty else {
            return []
        }

        var seenIds: Set<Int64> = []
        var result: [MessageRecord] = []

        func append(_ rows: [MessageRecord]) {
            for row in rows {
                guard let id = row.id, seenIds.insert(id).inserted else { continue }
                result.append(row)
            }
        }

        for chunk in Array(candidateMessageIds).chunked(into: 400) {
            let rows = try MessageRecord.fetchAll(
                db,
                sql: """
                SELECT message.* FROM message
                JOIN mailbox ON mailbox.id = message.mailboxId
                WHERE mailbox.accountId = ? AND message.threadId IS NOT NULL AND message.messageId IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                """,
                arguments: StatementArguments([accountId] + chunk)
            )
            append(rows)
        }

        for chunk in Array(candidateGmailThreadIds).chunked(into: 400) {
            let rows = try MessageRecord.fetchAll(
                db,
                sql: """
                SELECT message.* FROM message
                JOIN mailbox ON mailbox.id = message.mailboxId
                WHERE mailbox.accountId = ? AND message.threadId IS NOT NULL AND message.gmailThreadId IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                """,
                arguments: StatementArguments([accountId] + chunk)
            )
            append(rows)
        }

        for chunk in Array(candidateSubjects).chunked(into: 400) {
            let rows = try MessageRecord.fetchAll(
                db,
                sql: """
                SELECT message.* FROM message
                JOIN mailbox ON mailbox.id = message.mailboxId
                WHERE mailbox.accountId = ? AND message.threadId IS NOT NULL AND message.normalizedSubject IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                """,
                arguments: StatementArguments([accountId] + chunk)
            )
            append(rows)
        }

        return result
    }

    private static func messageCounts(forThreadIds threadIds: Set<Int64>, db: Database) throws -> [Int64: Int] {
        guard !threadIds.isEmpty else { return [:] }
        var result: [Int64: Int] = [:]
        for chunk in Array(threadIds).chunked(into: 400) {
            let threads = try ThreadRecord.filter(chunk.contains(Column("id"))).fetchAll(db)
            for thread in threads {
                guard let id = thread.id else { continue }
                result[id] = thread.messageCount
            }
        }
        return result
    }

    /// Applies a computed `BatchThreader.Plan` to the database: inserts new
    /// threads, reparents/deletes merged-away existing threads, bulk-writes
    /// every previously-unthreaded message's new `threadId`, and recomputes
    /// aggregates for every thread this batch touched — all in a small,
    /// fixed-ish number of statements rather than one per message.
    private static func apply(_ plan: BatchThreader.Plan, accountId: String, db: Database) throws {
        var realIdForNewIndex: [Int64] = []
        realIdForNewIndex.reserveCapacity(plan.newThreadSubjects.count)
        for subject in plan.newThreadSubjects {
            var thread = ThreadRecord(accountId: accountId, normalizedSubject: subject)
            try thread.insert(db)
            realIdForNewIndex.append(thread.id!)
        }

        func resolve(_ target: BatchThreader.ThreadTarget) -> Int64 {
            switch target {
            case .existing(let id): return id
            case .new(let index): return realIdForNewIndex[index]
            }
        }

        if !plan.reparentedThreadIds.isEmpty {
            var losersByTarget: [Int64: [Int64]] = [:]
            for (loser, target) in plan.reparentedThreadIds {
                losersByTarget[resolve(target), default: []].append(loser)
            }
            for (target, losers) in losersByTarget {
                for chunk in losers.chunked(into: 400) {
                    try db.execute(
                        sql: "UPDATE message SET threadId = ? WHERE threadId IN (\(chunk.map { _ in "?" }.joined(separator: ",")))",
                        arguments: StatementArguments([target] + chunk)
                    )
                }
            }
            for chunk in Array(plan.reparentedThreadIds.keys).chunked(into: 400) {
                try ThreadRecord.filter(chunk.contains(Column("id"))).deleteAll(db)
            }
        }

        var touchedThreadIds: Set<Int64> = []
        for chunk in plan.assignments.map({ (messageId: $0.key, threadId: resolve($0.value)) }).chunked(into: 400) {
            touchedThreadIds.formUnion(chunk.map(\.threadId))
            let whenClauses = chunk.map { _ in "WHEN ? THEN ?" }.joined(separator: " ")
            let idPlaceholders = chunk.map { _ in "?" }.joined(separator: ",")
            var arguments: [DatabaseValueConvertible] = []
            for pair in chunk {
                arguments.append(pair.messageId)
                arguments.append(pair.threadId)
            }
            for pair in chunk {
                arguments.append(pair.messageId)
            }
            try db.execute(
                sql: "UPDATE message SET threadId = CASE id \(whenClauses) END WHERE id IN (\(idPlaceholders))",
                arguments: StatementArguments(arguments)
            )
        }

        for chunk in Array(touchedThreadIds).chunked(into: 400) {
            let idPlaceholders = chunk.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: """
                UPDATE thread SET
                    messageCount = (SELECT COUNT(*) FROM message WHERE message.threadId = thread.id),
                    unreadCount = (SELECT COUNT(*) FROM message WHERE message.threadId = thread.id AND (message.flagsRaw & \(MessageFlags.seen.rawValue)) = 0),
                    lastMessageDate = (SELECT MAX(COALESCE(message.date, message.internalDate)) FROM message WHERE message.threadId = thread.id)
                WHERE thread.id IN (\(idPlaceholders))
                """,
                arguments: StatementArguments(chunk)
            )
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

/// Splits `self` into consecutive slices of at most `size` elements — used
/// by `ThreadAssigner`'s batched `assignAllUnthreaded` to keep every bulk
/// `IN (...)`/`CASE ... WHEN` statement's parameter count comfortably under
/// SQLite's bound-parameter limit, regardless of how large a single batch
/// (or its candidate-key fan-out) gets.
private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
