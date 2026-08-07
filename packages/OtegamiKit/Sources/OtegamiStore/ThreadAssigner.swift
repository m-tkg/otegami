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
            gmailThreadId: message.gmailThreadId,
            fromAddress: message.fromAddresses.first?.address
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
                gmailThreadId: message.gmailThreadId,
                fromAddress: message.fromAddresses.first?.address
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
                sql: aggregateUpdateSQL(whereClause: "WHERE thread.id IN (\(idPlaceholders))"),
                arguments: StatementArguments(chunk)
            )
        }
    }

    // Gmail 二重ラベル対策の重複排除: `messageCount`/`unreadCount`は
    // `ThreadQuery.deduplicate(_:db:)`と同じ「同一物理メールが INBOX と
    // All Mail に別 message 行として存在する」ケースを二重カウントしない
    // よう、ここも同じ同一性定義 (gmailMessageId優先、無ければmessageId、
    // 両方nilなら重複排除しない) で数える。この一括パスは初回同期/レガシー
    // アカウントの一括バックフィル (数千スレッド規模になりうる —
    // `assignAllUnthreaded`のdoc comment参照) や `recomputeAllAggregates`の
    // 全件バックフィル (Task #168) からも呼ばれるため、スレッドごとに
    // Swiftへ取得し直す (`ThreadAssigner.recomputeAggregates(threadId:
    // db:)`) 方式だとこのバッチ化がそもそも解決したかった「1メッセージ
    // ごとに何往復もする」遅さへ逆戻りしかねない — 単一UPDATE文の中で
    // SQLのwindow関数を使い、`ThreadQuery.deduplicate`と同じ「role持ちの
    // メールボックスをAll Mail相当より優先」というタイブレークをSQL側に
    // 再現する。`messageCount`は同一性キーの distinct 件数を数えるだけで
    // 済む (どちらの行が「勝つ」かはcountに影響しない) が、`unreadCount`は
    // 各グループの「勝った」行の既読状態だけを見る必要があるため
    // (同じメールでもINBOX側とAll Mail側で`\Seen`フラグが食い違うことが
    // ありうる) `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)`で
    // グループ内の代表行 (rn = 1) を選び出す。`isPinned`も同じ理由で同じ
    // 代表行だけを見る — 元は`MAX(isPinnedLocal)`(生の全行のOR) で
    // 「MAXベースなので重複に対して安全」という判断だったが、それは
    // 二重カウントしないという意味であって「片方の行だけ古い」状態には
    // 安全ではなかった (実機報告 2026-08-07「メールの unpin が反映され
    // ない」— 詳細は`recomputeAggregates(threadId:db:)`のコメント)。
    // `lastMessageDate`だけはMAXのまま — 日時は重複行のどちらを見ても
    // 同じ値なので、dedupしてもしなくても結果が変わらない。
    //
    // `whereClause`はどの`thread`行を更新するかを絞る節 (呼び出し側が
    // "WHERE thread.id IN (...)"を渡すか、`recomputeAllAggregates`のように
    // 空文字列を渡して全スレッドを対象にするか)。`identityKeySQL`/
    // `roleBearingRankSQL`/このUPDATE文自体を`apply`と`recomputeAllAggregates`
    // の2箇所で定義し直さず、この1箇所にまとめておくことで定義が散らばって
    // 食い違う事故を防ぐ。
    private static func aggregateUpdateSQL(whereClause: String) -> String {
        let identityKeySQL = """
            CASE
                WHEN message.gmailMessageId IS NOT NULL THEN 'g:' || message.gmailMessageId
                WHEN message.messageId IS NOT NULL THEN 'm:' || message.messageId
                ELSE 'u:' || message.id
            END
            """
        let roleBearingRankSQL = """
            CASE WHEN mailbox.role IN ('inbox', 'sent', 'drafts', 'trash', 'junk', 'archive') THEN 1 ELSE 0 END
            """
        return """
            UPDATE thread SET
                messageCount = (
                    SELECT COUNT(DISTINCT \(identityKeySQL))
                    FROM message WHERE message.threadId = thread.id
                ),
                unreadCount = (
                    SELECT COUNT(*) FROM (
                        SELECT message.flagsRaw AS flagsRaw,
                               ROW_NUMBER() OVER (
                                   PARTITION BY \(identityKeySQL)
                                   ORDER BY \(roleBearingRankSQL) DESC, message.uid DESC
                               ) AS rn
                        FROM message
                        JOIN mailbox ON mailbox.id = message.mailboxId
                        WHERE message.threadId = thread.id
                    )
                    WHERE rn = 1 AND (flagsRaw & \(MessageFlags.seen.rawValue)) = 0
                ),
                lastMessageDate = (SELECT MAX(COALESCE(message.date, message.internalDate)) FROM message WHERE message.threadId = thread.id),
                isPinned = (
                    SELECT COALESCE(MAX(isPinnedLocal), 0) FROM (
                        SELECT message.isPinnedLocal AS isPinnedLocal,
                               ROW_NUMBER() OVER (
                                   PARTITION BY \(identityKeySQL)
                                   ORDER BY \(roleBearingRankSQL) DESC, message.uid DESC
                               ) AS rn
                        FROM message
                        JOIN mailbox ON mailbox.id = message.mailboxId
                        WHERE message.threadId = thread.id
                    )
                    WHERE rn = 1
                )
            \(whereClause)
            """
    }

    /// One-time full-table recompute of every thread's `messageCount`/
    /// `unreadCount`/`lastMessageDate`/`isPinned`, using the exact same
    /// dedup-aware SQL `apply`'s per-batch aggregate refresh uses (see
    /// `aggregateUpdateSQL`'s doc comment) — just with no `WHERE thread.id
    /// IN (...)` restriction, so it's a single `UPDATE` statement covering
    /// every row in `thread` regardless of table size, not a chunked loop.
    ///
    /// Exists for the v35 migration (Task #168, 実機フィードバック「一覧の
    /// スレッド通数バッジが実際の通数と食い違う」): a54f585 made
    /// `messageCount`/`unreadCount` dedup-aware (Gmail's INBOX/All Mail
    /// 二重行を除外) for every *future* write to those columns, but never
    /// backfilled threads whose stored value was already written with the
    /// old (non-dedup) count before that fix shipped — those stayed wrong
    /// until something else changed that thread's membership and triggered
    /// a fresh `recomputeAggregates`/`apply` write. Safe to call outside a
    /// migration too (e.g. from a diagnostics path) since it's read-derived
    /// and idempotent.
    public static func recomputeAllAggregates(db: Database) throws {
        try db.execute(sql: aggregateUpdateSQL(whereClause: ""))
    }

    /// Recomputes `messageCount`/`unreadCount`/`lastMessageDate` for
    /// `threadId` from its current member messages, or deletes the thread
    /// row outright if it no longer has any (the last message in it was
    /// deleted, or every message got reparented away by a merge). Call
    /// after any mutation that could change a thread's membership or a
    /// member's `\Seen` flag: message insert/re-thread (handled internally
    /// by `assignThread`), flag toggle, and message deletion.
    public static func recomputeAggregates(threadId: Int64, db: Database) throws {
        let rawMessages = try MessageRecord.filter(Column("threadId") == threadId).fetchAll(db)
        guard !rawMessages.isEmpty else {
            try ThreadRecord.deleteOne(db, key: threadId)
            return
        }
        guard var thread = try ThreadRecord.fetchOne(db, key: threadId) else { return }
        // `messageCount`/`unreadCount`/`isPinned`はGmail二重ラベル対策の
        // 重複排除後の行で計算する (`ThreadQuery.deduplicate(_:db:)` —
        // 一括パスの `apply` 内SQLと同じ同一性定義/タイブレークを共有する、
        // 単一の実装)。
        //
        // `isPinned`は元々「MAXベースで重複に対してそもそも安全」という判断で
        // 生の`rawMessages`のORだったが、これが実機報告 (2026-08-07)
        // 「メールの unpin が反映されない」の3番目の層だった: 行アクションの
        // 対象解決 (`ThreadQuery.actionTargets`) は dedup 済みの代表行しか
        // 触らないのに、集約だけが dedup 前の全行を見ていたため、All Mail
        // 側の行が1つ`true`のまま残るだけでピンが永久に落ちなかった
        // (逆にピン留めはORなので代表行だけで効き、非対称なバグに見えた)。
        // 「重複に対して安全」なのは二重カウントしないという意味であって、
        // 「片方の行だけ古い」状態には安全ではなかった。
        //
        // `lastMessageDate`だけは生の`rawMessages`のまま — 日時は重複行の
        // どちらを見ても同じ値で、dedupしてもしなくてもMAXは変わらない。
        let messages = try ThreadQuery.deduplicate(rawMessages, db: db)
        thread.messageCount = messages.count
        thread.unreadCount = messages.filter { !$0.flags.contains(.seen) }.count
        thread.lastMessageDate = rawMessages.compactMap { $0.date ?? $0.internalDate }.max()
        thread.isPinned = messages.contains { $0.isPinnedLocal }
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

    // MARK: - Task #193 repair: already-stored sentinel dates

    /// Task #193 (実機バグ「10年以上前に送った送信済みメールが、6時間前
    /// くらいの日付で受信箱に表示される」): repairs `message` rows already
    /// corrupted by the MailCore2 sentinel-date bug (`EnvelopeDateSentinel`'s
    /// doc comment has the full mailcore2-side root cause) *before* the fix
    /// in `MailCoreIMAPSession+Mapping.envelope(from:fetchedAt:)` shipped —
    /// that fix only prevents the corruption on every future fetch; it does
    /// nothing for a `date` already written, or for a thread a corrupted row
    /// already merged into via `Threader`'s subject-fallback pass (§3: same
    /// normalized subject, overlapping participants, within 7 days — a
    /// years-old message whose `date` looked like "just now" easily lands
    /// inside that window against whatever recent thread happens to share
    /// its subject and a participant).
    ///
    /// The exact `fetchedAt` moment that produced a given corrupted `date`
    /// isn't stored anywhere, so this reuses `message.updatedAt` — the
    /// timestamp `AccountSyncer.upsert` stamps on *every* write — as the
    /// best available stand-in: a genuinely corrupted row has `date` and
    /// `updatedAt` written together in the very same upsert, so they're
    /// exactly as close as a real `fetchedAt` would have made them; a
    /// healthy row's `date` (matching `internalDate`, or legitimately
    /// far from `updatedAt` for a long-since-synced message) doesn't
    /// false-positive here for the same reasons `EnvelopeDateSentinel`'s
    /// own doc comment explains for the real-time case.
    ///
    /// For every row this flags: clears `date` (letting every existing
    /// `date ?? internalDate` reader fall back to the trustworthy
    /// `internalDate` automatically, same as the ordinary "no `Date:`
    /// header at all" case already does) and re-runs `assignThread` — which
    /// may join a different (or brand new) thread now that `Threader` sees
    /// its real date. The thread it's *leaving*, if any, gets its
    /// aggregates recomputed too (and is deleted outright if this was its
    /// last remaining message) — `assignThread` alone only ever settles the
    /// thread a message *joins*.
    ///
    /// Returns the number of rows repaired. Safe to call unconditionally
    /// (a no-op account with nothing corrupted just does one query and
    /// returns `0`) — used both by the `AppDatabase` migration that runs
    /// this once for every existing install, and available to call again
    /// on demand (e.g. a future diagnostics path) since it's idempotent.
    @discardableResult
    public static func repairSentinelDates(db: Database) throws -> Int {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT message.id AS id, message.date AS date, message.internalDate AS internalDate,
                       message.updatedAt AS updatedAt, message.threadId AS threadId, mailbox.accountId AS accountId
                FROM message
                JOIN mailbox ON mailbox.id = message.mailboxId
                WHERE message.date IS NOT NULL
                """
        )

        var repairedCount = 0
        var vacatedThreadIds: Set<Int64> = []
        for row in rows {
            guard
                let messageId: Int64 = row["id"],
                let date: Date = row["date"],
                let internalDate: Date = row["internalDate"],
                let updatedAt: Date = row["updatedAt"],
                let accountId: String = row["accountId"]
            else { continue }
            guard EnvelopeDateSentinel.isSuspicious(date: date, internalDate: internalDate, referenceTime: updatedAt) else {
                continue
            }

            let oldThreadId: Int64? = row["threadId"]
            try db.execute(sql: "UPDATE message SET date = NULL WHERE id = ?", arguments: [messageId])
            let newThreadId = try assignThread(messageId: messageId, accountId: accountId, db: db)
            if let oldThreadId, oldThreadId != newThreadId {
                vacatedThreadIds.insert(oldThreadId)
            }
            repairedCount += 1
        }

        for threadId in vacatedThreadIds {
            try recomputeAggregates(threadId: threadId, db: db)
        }

        return repairedCount
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
