import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

/// 実機報告「Gmail の未送信 op が1055件・最古 enqueue 約17時間・attempts
/// が1件も増えない」の修正検証: `session.connect(auth:)`/`apply(...)`が
/// 返ってこない (ハング) ケースで`replay(account:auth:)`が永久ロックせず
/// タイムアウトで抜けること、`inFlightAccountIds`が解放されて後続の
/// replay が実行できること、スタックした in-flight を奪い取れること、
/// 大きな滞留がバッチ分割で複数パスに分かれて全件処理されることを検証
/// する。既存の`OpQueueProcessorReplayLogTests`/`OpQueueProcessorSetFlagsTests`
/// と同じ`FakeIMAPSession`/`AppDatabase.makeInMemory()`ベースの作法に
/// 揃えた。
@Suite("OpQueueProcessor replay — stuck replay recovery (timeout / stale takeover / batching)")
struct OpQueueProcessorStuckReplayTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
    }

    private func makeAccountWithMailboxes(database: AppDatabase, inboxUidValidity: Int64 = 1) async throws -> (account: AccountRecord, inbox: MailboxRecord) {
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let inbox = try await database.dbWriter.write { db -> MailboxRecord in
            var record = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: inboxUidValidity)
            try record.insert(db)
            return record
        }
        return (account, inbox)
    }

    private let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

    /// 同じ`sessionFactory`を複数回呼んだときに、呼び出し順で異なる
    /// `FakeIMAPSession.Script`を返すためのカウンタ — `sessionFactory`は
    /// 同期クロージャ (`@Sendable (IMAPConfig) -> any IMAPSessionProtocol`)
    /// なので、actorではなくロック付きクラス (`FakeIMAPSession
    /// .CallRecorder`/`FlakyCallController`と同じ形) にした。
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
    }

    // MARK: - 1. connect() のハング → タイムアウトで中断 → in-flight 解放

    @Test("a hung connect() times out, aborts with a connection-level error, and releases in-flight so a later replay can proceed")
    func hungConnectTimesOutAndReleasesInFlight() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithMailboxes(database: database)
        try await database.dbWriter.write { db in
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [1], flags: .seen, db: db
            )
        }

        // Never `open()`ed — models a `connect()` that never returns (the
        // real-device failure mode: MailCore2's callback simply never
        // fires).
        let connectGate = FakeIMAPSession.AsyncCallGate()
        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:], connectGate: connectGate)
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: script, recorder: recorder) },
            connectTimeout: 0.05
        )

        await #expect(throws: (any Error).self) {
            try await processor.replay(account: account, auth: auth)
        }

        // Connection-level failure: the op is untouched, not counted
        // against its attempts budget (`replayPass`'s doc comment).
        let opsAfterFirstAttempt = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        let op = try #require(opsAfterFirstAttempt.first)
        #expect(op.attempts == 0)

        let entriesAfterFirstAttempt = try await database.dbWriter.read { db in try OpQueueReplayLogRecord.fetchAll(db) }
        let firstEntry = try #require(entriesAfterFirstAttempt.first)
        #expect(firstEntry.parsedOutcome == .aborted)
        let firstErrorDescription = try #require(firstEntry.errorDescription)
        #expect(firstErrorDescription.contains("タイムアウト"))

        // The crucial assertion: `inFlightAccountIds` was released by
        // `replay`'s `defer` despite the timeout throw, so this second call
        // doesn't just `.coalesced` — it actually opens a brand-new
        // connection (same never-opened gate, so it also times out, but
        // that's still proof the guard wasn't left permanently held).
        await #expect(throws: (any Error).self) {
            try await processor.replay(account: account, auth: auth)
        }
        #expect(recorder.connectCalls.count == 2)

        let entriesAfterSecondAttempt = try await database.dbWriter.read { db in try OpQueueReplayLogRecord.fetchAll(db) }
        #expect(entriesAfterSecondAttempt.count == 2)
        #expect(entriesAfterSecondAttempt.allSatisfy { $0.parsedOutcome == .aborted })
    }

    // MARK: - 2. apply() のハング (STORE 送信中) → タイムアウトで中断 → in-flight 解放

    @Test("a hung op apply() times out, aborts with a connection-level error, and releases in-flight so a later replay can proceed")
    func hungApplyTimesOutAndReleasesInFlight() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithMailboxes(database: database)
        try await database.dbWriter.write { db in
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [1], flags: .seen, db: db
            )
        }

        // Never `open()`ed — models `session.store(...)` (inside `apply`)
        // hanging mid-`STORE` rather than the connect itself.
        let storeGate = FakeIMAPSession.AsyncCallGate()
        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:], storeGate: storeGate)
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: script, recorder: recorder) },
            opApplyTimeout: 0.05
        )

        await #expect(throws: (any Error).self) {
            try await processor.replay(account: account, auth: auth)
        }

        let opsAfterFirstAttempt = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        let op = try #require(opsAfterFirstAttempt.first)
        #expect(op.attempts == 0)

        let entriesAfterFirstAttempt = try await database.dbWriter.read { db in try OpQueueReplayLogRecord.fetchAll(db) }
        let firstEntry = try #require(entriesAfterFirstAttempt.first)
        #expect(firstEntry.parsedOutcome == .aborted)
        let firstErrorDescription = try #require(firstEntry.errorDescription)
        #expect(firstErrorDescription.contains("タイムアウト"))

        // Same in-flight-released assertion as the connect-timeout test,
        // for the op-apply timeout path.
        await #expect(throws: (any Error).self) {
            try await processor.replay(account: account, auth: auth)
        }
        #expect(recorder.connectCalls.count == 2)
    }

    // MARK: - 3. スタックした in-flight の奪い取り

    @Test("a stale in-flight replay (older than the threshold) is taken over by a subsequent call instead of coalescing forever")
    func staleInFlightReplayIsTakenOver() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithMailboxes(database: database)
        try await database.dbWriter.write { db in
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [1], flags: .seen, db: db
            )
        }

        // Never `open()`ed — the first `replay` call's `connect()` hangs
        // for the remainder of this test (cleaned up at the end). A large
        // `connectTimeout` (effectively "no timeout" on this test's own
        // timescale) keeps the timeout mechanism from item 1 above out of
        // the picture, so only the stale-takeover path is exercised.
        let connectGate = FakeIMAPSession.AsyncCallGate()
        let recorder = FakeIMAPSession.CallRecorder()
        let gatedScript = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:], connectGate: connectGate)
        let plainScript = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let counter = CallCounter()
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in
                // Only the *first* connect (the one that gets permanently
                // stuck) uses the gated script — every later connect
                // (the stale-takeover pass below) gets a plain script that
                // connects immediately, so the takeover pass can actually
                // make progress rather than blocking on the same gate.
                let script = counter.next() == 1 ? gatedScript : plainScript
                return FakeIMAPSession(config: config, script: script, recorder: recorder)
            },
            connectTimeout: 999,
            staleInFlightThreshold: 0.05
        )

        let stuckReplay = Task { try? await processor.replay(account: account, auth: auth) }
        await connectGate.waitUntilEntered()

        // Longer than `staleInFlightThreshold` (0.05s) so the next call
        // sees `age >= staleInFlightThreshold` and takes over rather than
        // coalescing.
        try await Task.sleep(for: .milliseconds(150))

        let takeoverResult = try await processor.replay(account: account, auth: auth)
        // A `.coalesced` result would be an all-zero `ReplayResult()` — a
        // non-zero `succeeded` here is proof the takeover pass actually
        // connected and applied the op itself, not that it just coalesced.
        #expect(takeoverResult.succeeded == 1)
        #expect(recorder.connectCalls.count == 2)

        let entries = try await database.dbWriter.read { db in try OpQueueReplayLogRecord.fetchAll(db) }
        let takeoverEntry = try #require(entries.first { $0.errorDescription?.contains("スタック検出") == true })
        #expect(takeoverEntry.parsedOutcome == .completed)
        #expect(takeoverEntry.succeeded == 1)

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remaining.isEmpty)

        // Clean up the permanently-stuck first call so it doesn't leak a
        // hung task past this test.
        await connectGate.open()
        _ = await stuckReplay.value
    }

    // MARK: - 4. バッチ分割: due op がバッチ上限を超えても複数パスで全件処理される

    @Test("a due-op backlog larger than replayBatchLimit is processed across multiple passes, not dropped")
    func largeBacklogIsProcessedAcrossMultiplePasses() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithMailboxes(database: database)

        let opCount = 7
        let batchLimit = 3
        try await database.dbWriter.write { db in
            for uid in 1...opCount {
                try OpQueue.enqueueSetFlags(
                    accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                    uids: [UInt32(uid)], flags: .seen, db: db
                )
            }
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: script, recorder: recorder) },
            replayBatchLimit: batchLimit
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == opCount)

        #expect(recorder.storeCalls.count == opCount)
        // ceil(7/3) == 3 passes, each opening its own connection (existing
        // per-pass session-scoped behavior, unchanged by batching).
        #expect(recorder.connectCalls.count == 3)

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remaining.isEmpty)

        let entries = try await database.dbWriter.read { db in try OpQueueReplayLogRecord.fetchAll(db) }
        // `replay(account:auth:)` logs once per *call* (not per internal
        // pass) — one `.completed` entry whose aggregated counts cover
        // every pass.
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.parsedOutcome == .completed)
        #expect(entry.succeeded == opCount)
    }
}
