import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

/// 実機報告「Gmail で既読化/アーカイブしてもサーバに反映されず、再読込で
/// サーバ状態に巻き戻る」の調査可能化: `OpQueueProcessor.replay`が
/// `opQueueReplayLog`へ実行履歴を残すこと自体を検証する — 設定の
/// 「操作同期の診断」画面 (`OpQueueDiagnosticsView`) がこの表を読む。
@Suite("OpQueueProcessor replay — replay log persistence")
struct OpQueueProcessorReplayLogTests {
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

    @Test("a replay with a due op logs a completed entry with matching counts")
    func replayLogsCompletedEntryWithCounts() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithMailboxes(database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [1], flags: .seen, db: db
            )
        }

        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script)
        }

        let before = Date()
        _ = try await processor.replay(account: account, auth: auth)

        let entries = try await database.dbWriter.read { db in try OpQueueReplayLogRecord.fetchAll(db) }
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.accountId == account.id)
        #expect(entry.parsedOutcome == .completed)
        #expect(entry.succeeded == 1)
        #expect(entry.discardedStale == 0)
        // GRDB's `.datetime` column round-trips a `Date` at millisecond
        // precision, so the value read back can be a fraction of a
        // millisecond *before* `before` (captured with full sub-millisecond
        // precision) even though it was written strictly after — tolerate
        // that rounding rather than asserting a strict `>=`.
        #expect(entry.invokedAt.timeIntervalSince(before) > -0.01)
        let completedAt = try #require(entry.completedAt)
        #expect(completedAt.timeIntervalSince(entry.invokedAt) > -0.01)
        #expect(entry.errorDescription == nil)
    }

    @Test("a replay against an empty queue still logs a completed (no-op) entry, distinct from never being invoked")
    func replayLogsCompletedEntryEvenWhenQueueIsEmpty() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _) = try await makeAccountWithMailboxes(database: database)

        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script)
        }

        _ = try await processor.replay(account: account, auth: auth)

        let entries = try await database.dbWriter.read { db in try OpQueueReplayLogRecord.fetchAll(db) }
        let entry = try #require(entries.first)
        #expect(entry.parsedOutcome == .completed)
        #expect(entry.succeeded == 0)
    }

    @Test("a connection-level failure logs an aborted entry with the error description")
    func replayLogsAbortedEntryOnConnectionFailure() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox) = try await makeAccountWithMailboxes(database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [1], flags: .seen, db: db
            )
        }

        let script = FakeIMAPSession.Script(failConnection: .connectionFailed(underlyingDescription: "simulated connection failure"))
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script)
        }

        do {
            _ = try await processor.replay(account: account, auth: auth)
            Issue.record("expected replay to rethrow the connection-level failure")
        } catch {
            // Expected — `replay` rethrows connect() failures unchanged.
        }

        let entries = try await database.dbWriter.read { db in try OpQueueReplayLogRecord.fetchAll(db) }
        let entry = try #require(entries.first)
        #expect(entry.parsedOutcome == .aborted)
        #expect(entry.succeeded == 0)
        let errorDescription = try #require(entry.errorDescription)
        #expect(!errorDescription.isEmpty)
    }

    @Test("the ring buffer keeps only the most recent replayLogCap entries")
    func replayLogTrimsToCap() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _) = try await makeAccountWithMailboxes(database: database)

        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script)
        }

        // One more than the cap — every call is a no-op (empty queue), so
        // this only exercises `beginReplayLog`'s trimming, not the replay
        // logic itself.
        for _ in 0..<(OpQueueProcessor.replayLogCap + 1) {
            _ = try await processor.replay(account: account, auth: auth)
        }

        let entries = try await database.dbWriter.read { db in try OpQueueReplayLogRecord.fetchAll(db) }
        #expect(entries.count == OpQueueProcessor.replayLogCap)
    }
}
