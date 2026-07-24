import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// M10 performance verification (plan: "合成データで10万通... 一覧 ThreadQuery
/// (統合Inboxの首頁50行)、検索、ThreadAssigner backfillを計測。目標: 一覧クエリ
/// <100ms、検索<500ms"). Opt-in and skipped by default (`make test`/CI never
/// runs this): seeding + threading 100k messages takes tens of seconds, far
/// outside what a routine `swift test` run should cost. Run explicitly with:
///
///   OTEGAMI_PERF_TEST=1 swift test --filter PerformanceTests
///
/// Numbers this test prints (via `Testing`'s `Test.current` comment output —
/// run with `-v`/watch the console) were captured once into
/// docs/performance.md; re-run and update that file if a future change to
/// the schema/queries could plausibly move them.
///
/// Uses a real on-disk `DatabasePool` (not `AppDatabase.makeInMemory()`'s
/// `DatabaseQueue`) — a `DatabaseQueue` never touches disk at all, which
/// would make WAL checkpointing, page-cache-cold reads, and every other
/// disk-I/O-shaped cost this test cares about simply not exist. A real app
/// on a real device pays those costs.
@Suite("Performance (100k messages)", .enabled(if: ProcessInfo.processInfo.environment["OTEGAMI_PERF_TEST"] == "1"))
struct PerformanceTests {
    /// Total synthetic message count across both accounts — the plan's
    /// "10万通" target.
    static let totalMessageCount = 100_000
    /// account1 gets pre-threaded messages (simulating the common case:
    /// `AccountSyncer.upsert` threads each message as it's synced, so most
    /// of a mailbox's history was never in the "unthreaded" backlog at
    /// once). account2's share is inserted with `threadId == nil` and
    /// threaded in one `ThreadAssigner.assignAllUnthreaded` backfill pass,
    /// timed — the plan's "ThreadAssigner backfill" checkpoint. Kept
    /// smaller than account1's share because backfill cost scales
    /// super-linearly (`ThreadAssigner.buildContext`'s per-message
    /// candidate queries) — 20k is already representative of "reopen the
    /// app after a long time offline", not an unrealistic worst case.
    static let backfillMessageCount = 20_000
    static let threadedMessageCount = totalMessageCount - backfillMessageCount
    /// Only a fraction of messages get a `messageBody` row — plan: "本文は
    /// 一部のみ", matching real sync behavior (`BodyFetcher.prefetchRecent`
    /// only pre-fetches the newest ~50 per mailbox; the rest are fetched
    /// lazily on open).
    static let bodyFraction = 20

    private func makeFileBackedDatabase() throws -> (database: AppDatabase, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("otegami-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("otegami-perf.sqlite")
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        let database = try AppDatabase(pool)
        // OTEGAMI_PERF_KEEP_DB=1: skip cleanup so the seeded database can be
        // inspected afterward (e.g. `sqlite3` against the printed path, to
        // compare a query plan/timing against what's measured here) —
        // used once while writing docs/performance.md's before/after
        // numbers; not needed for a normal perf run.
        if ProcessInfo.processInfo.environment["OTEGAMI_PERF_KEEP_DB"] == "1" {
            print("[perf] keeping database at \(url.path)")
            return (database, {})
        }
        return (database, { try? FileManager.default.removeItem(at: directory) })
    }

    @Test("seed 100k messages, then measure unified-inbox listing, search, and thread backfill")
    func hundredThousandMessages() async throws {
        let (database, cleanup) = try makeFileBackedDatabase()
        defer { cleanup() }

        let account1 = AccountRecord(
            displayName: "Perf Account 1", email: "perf1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "perf1@otegami.test"
        )
        let account2 = AccountRecord(
            displayName: "Perf Account 2", email: "perf2@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "perf2@otegami.test"
        )

        let (inbox1, sent1, inbox2) = try await database.dbWriter.write { db -> (Int64, Int64, Int64) in
            try account1.insert(db)
            try account2.insert(db)
            var i1 = MailboxRecord(accountId: account1.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            try i1.insert(db)
            var s1 = MailboxRecord(accountId: account1.id, path: "Sent", displayPath: "Sent", role: .sent)
            try s1.insert(db)
            var i2 = MailboxRecord(accountId: account2.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            try i2.insert(db)
            return (i1.id!, s1.id!, i2.id!)
        }

        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let seedStart = CFAbsoluteTimeGetCurrent()
        // account1: pre-threaded (one thread per message — the worst case
        // for "how many rows does a mailbox-scoped ThreadQuery see", since
        // no thread-count reduction from grouping happens). 90% INBOX, 10%
        // Sent, so the unified-inbox query (inbox-role only) still has to
        // filter, not just return everything in `thread`.
        try await database.dbWriter.write { db in
            for i in 0..<Self.threadedMessageCount {
                let mailboxId = i % 10 == 0 ? sent1 : inbox1
                let date = base.addingTimeInterval(Double(i))
                var thread = ThreadRecord(accountId: account1.id, normalizedSubject: "perf subject \(i)", lastMessageDate: date, messageCount: 1)
                try thread.insert(db)
                var message = MessageRecord(
                    mailboxId: mailboxId, uid: Int64(i + 1),
                    subject: "Perf message \(i)", normalizedSubject: "perf subject \(i)",
                    date: date, internalDate: date, threadId: thread.id
                )
                try message.insert(db)
                if i % Self.bodyFraction == 0 {
                    var body = MessageBodyRecord(messageId: message.id!, plainText: "Body text for message \(i). 日本語の本文サンプルです。")
                    try body.insert(db)
                }
            }

            // account2: unthreaded on purpose (see the type doc comment) —
            // the ThreadAssigner backfill checkpoint below threads these.
            for i in 0..<Self.backfillMessageCount {
                let date = base.addingTimeInterval(Double(Self.threadedMessageCount + i))
                var message = MessageRecord(
                    mailboxId: inbox2, uid: Int64(i + 1),
                    subject: "Backfill message \(i)", normalizedSubject: "backfill subject \(i)",
                    date: date, internalDate: date
                )
                try message.insert(db)
            }
        }
        let seedElapsed = (CFAbsoluteTimeGetCurrent() - seedStart) * 1000
        print("[perf] seed \(Self.totalMessageCount) messages: \(String(format: "%.1f", seedElapsed))ms")

        // Checkpoint 1: unified inbox first page (top 50), matching what
        // MessageListView actually requests (`ThreadQuery
        // .unifiedInboxSummariesObservation(accountIds:limit:)`). Target:
        // <100ms.
        let listStart = CFAbsoluteTimeGetCurrent()
        let firstPage = try await database.dbWriter.read { db in
            try ThreadQuery.summaries(
                forThreads: ThreadQuery.unifiedInboxRequest(accountIds: [account1.id, account2.id], limit: 50).fetchAll(db),
                db: db
            )
        }
        let listElapsed = (CFAbsoluteTimeGetCurrent() - listStart) * 1000
        print("[perf] unified inbox, first 50 threads: \(String(format: "%.1f", listElapsed))ms (\(firstPage.count) rows)")
        #expect(firstPage.count == 50)
        #expect(listElapsed < 100, "unified inbox first page took \(listElapsed)ms, target <100ms")

        // Checkpoint 2: a single mailbox's first page, same target.
        let mailboxListStart = CFAbsoluteTimeGetCurrent()
        let mailboxPage = try await database.dbWriter.read { db in
            try ThreadQuery.summaries(forThreads: ThreadQuery.request(mailboxId: inbox1, limit: 50).fetchAll(db), db: db)
        }
        let mailboxListElapsed = (CFAbsoluteTimeGetCurrent() - mailboxListStart) * 1000
        print("[perf] single mailbox, first 50 threads: \(String(format: "%.1f", mailboxListElapsed))ms (\(mailboxPage.count) rows)")
        #expect(mailboxListElapsed < 100, "mailbox first page took \(mailboxListElapsed)ms, target <100ms")

        // Checkpoint 3: search — FTS trigram MATCH (3+ chars) across all
        // accounts. `messageSearchIndex` isn't populated by this test's raw
        // inserts (only AccountSyncer.upsert/BodyFetcher index live), so
        // backfill it first the same way `FTSIndexer.backfillIfNeeded` does
        // at app startup, then measure the *query* alone. Target: <500ms.
        try await database.dbWriter.write { db in try FTSIndexer.backfillIfNeeded(db: db) }

        // "perf message" (both words 3+ characters, and "message" appears
        // in every account1 subject) is a realistic FTS hit — unlike a bare
        // 2-digit number, which the trigram tokenizer can't even form a
        // token from (confirmed while building this test: a query the
        // tokenizer reduces to zero tokens trivially matches nothing in
        // ~0ms, which would have silently measured "how fast is doing
        // nothing" instead of a real MATCH).
        let ftsStart = CFAbsoluteTimeGetCurrent()
        let ftsResults = try await database.dbWriter.read { db in
            try SearchQuery.threadSummaries(
                query: "perf message", scope: .allAccounts(accountIds: [account1.id, account2.id]), db: db
            )
        }
        let ftsElapsed = (CFAbsoluteTimeGetCurrent() - ftsStart) * 1000
        print("[perf] FTS search 'perf message' across both accounts: \(String(format: "%.1f", ftsElapsed))ms (\(ftsResults.count) threads)")
        #expect(ftsElapsed < 500, "FTS search took \(ftsElapsed)ms, target <500ms")

        // Checkpoint 4: the 2-character LIKE fallback — no index backs
        // `LIKE '%...%'`, so this is the pessimistic case (plan explicitly
        // calls out measuring both FTS and LIKE fallback).
        let likeStart = CFAbsoluteTimeGetCurrent()
        let likeResults = try await database.dbWriter.read { db in
            try SearchQuery.threadSummaries(
                query: "42", scope: .allAccounts(accountIds: [account1.id, account2.id]), db: db
            )
        }
        let likeElapsed = (CFAbsoluteTimeGetCurrent() - likeStart) * 1000
        print("[perf] LIKE fallback search '42' across both accounts: \(String(format: "%.1f", likeElapsed))ms (\(likeResults.count) threads)")
        #expect(likeElapsed < 500, "LIKE fallback search took \(likeElapsed)ms, target <500ms")

        // Checkpoint 5: ThreadAssigner backfill — the plan's explicit
        // checkpoint. Not asserted against a hard target (the plan gives
        // one for list/search queries, not this), just measured and
        // recorded.
        let backfillStart = CFAbsoluteTimeGetCurrent()
        try await database.dbWriter.write { db in
            try ThreadAssigner.assignAllUnthreaded(accountId: account2.id, db: db)
        }
        let backfillElapsed = (CFAbsoluteTimeGetCurrent() - backfillStart) * 1000
        print("[perf] ThreadAssigner.assignAllUnthreaded, \(Self.backfillMessageCount) messages: \(String(format: "%.1f", backfillElapsed))ms")

        // Checkpoint 6: "startup observation first fire" — approximated as
        // a cold ValueObservation's initial fetch (the same query
        // `MessageListView.observeThreads`'s `for try await` loop yields
        // from first), against the unified inbox now that account2's
        // messages are threaded too.
        let observationStart = CFAbsoluteTimeGetCurrent()
        var firstYieldElapsed: Double?
        let observation = ThreadQuery.unifiedInboxSummariesObservation(accountIds: [account1.id, account2.id], limit: 50)
        for try await summaries in observation.values(in: database.dbWriter) {
            firstYieldElapsed = (CFAbsoluteTimeGetCurrent() - observationStart) * 1000
            #expect(summaries.count == 50)
            break
        }
        if let firstYieldElapsed {
            print("[perf] ValueObservation first fire (unified inbox, limit 50): \(String(format: "%.1f", firstYieldElapsed))ms")
        }
    }
}
