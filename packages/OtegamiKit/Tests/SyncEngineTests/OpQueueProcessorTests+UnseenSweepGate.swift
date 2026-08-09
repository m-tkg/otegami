import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

/// 実機報告「Gmail のメールを既読にしてアーカイブしたのにバッジが 1 のまま
/// 消えない」の後半: `UnseenSweeper` が未送信 op に守られた UID を残数に
/// 数えなくなった (`UnseenSweeperTests`) 一方で、op が消えたあと**測り直す
/// きっかけ**が無ければ、今度は逆に残数が古いまま据え置かれる。
///
/// `ReplayResult.affectedMailboxIds` は移動系の移動元を意図的に外している
/// (`OpQueueProcessor` の doc comment) ので、アーカイブ元の INBOX は replay 後の
/// targeted resync に載らない。`OpQueueProcessor` が op を消すときに
/// `lastUnseenSweepAt` を `nil` に戻し、15 分ゲートだけ外しておく。
@Suite("OpQueueProcessor replay — unseen sweep gate")
struct OpQueueProcessorUnseenSweepGateTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
    }

    private let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

    /// An account with an INBOX and an Archive, both already swept (so the
    /// 15-minute gate is closed) and carrying a remainder — the state a
    /// device is in when the user archives something.
    private func makeSweptAccount(
        database: AppDatabase, inboxUidValidity: Int64 = 1
    ) async throws -> (account: AccountRecord, inbox: MailboxRecord, archive: MailboxRecord) {
        let account = makeAccount()
        return try await database.dbWriter.write { db in
            try account.insert(db)
            var inbox = MailboxRecord(
                accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox,
                uidValidity: inboxUidValidity, unseenNotFetchedCount: 1,
                lastUnseenSweepAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try inbox.insert(db)
            var archive = MailboxRecord(
                accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive,
                lastUnseenSweepAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try archive.insert(db)
            return (account, inbox, archive)
        }
    }

    private func mailbox(_ database: AppDatabase, _ id: Int64) async throws -> MailboxRecord {
        try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: id)! }
    }

    @Test("a replayed archive op reopens its source mailbox's sweep gate, without touching the remainder")
    func replayedArchiveReopensTheGate() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, archive) = try await makeSweptAccount(database: database)
        try await database.dbWriter.write { db in
            try OpQueue.enqueueArchive(
                accountId: account.id, sourceMailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [9], db: db
            )
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }
        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)

        let sweptInbox = try await mailbox(database, inbox.id!)
        #expect(sweptInbox.lastUnseenSweepAt == nil, "the 15-minute gate is off")
        #expect(UnseenSweeper.isDue(sweptInbox), "so the next incremental sync measures again")
        #expect(
            sweptInbox.unseenNotFetchedCount == 1,
            "the remainder itself is the sweep's job to correct, not this path's"
        )

        let untouched = try await mailbox(database, archive.id!)
        #expect(untouched.lastUnseenSweepAt != nil, "only the op's own mailbox is affected")
    }

    @Test("a replayed setFlags op reopens the gate for the mailbox it targets")
    func replayedSetFlagsReopensTheGate() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, archive) = try await makeSweptAccount(database: database)
        try await database.dbWriter.write { db in
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [9], flags: [.seen], db: db
            )
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }
        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)

        #expect(try await mailbox(database, inbox.id!).lastUnseenSweepAt == nil)
        #expect(try await mailbox(database, archive.id!).lastUnseenSweepAt != nil)
    }

    @Test("a stale-discarded op reopens the gate too — its guard is gone either way")
    func staleDiscardReopensTheGate() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _) = try await makeSweptAccount(database: database)
        // Enqueued against a uidValidity the mailbox no longer has: replay
        // discards it as `.staleDiscarded` rather than sending anything.
        try await database.dbWriter.write { db in
            try OpQueue.enqueueArchive(
                accountId: account.id, sourceMailboxId: inbox.id!, uidValidity: 999, uids: [9], db: db
            )
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }
        _ = try await processor.replay(account: account, auth: auth)

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchCount(db) }
        #expect(remaining == 0, "the op was discarded, so its guard is gone")
        #expect(try await mailbox(database, inbox.id!).lastUnseenSweepAt == nil)
    }

    @Test("a failing op keeps the gate closed — it is still in the queue, still guarding its UIDs")
    func failingOpKeepsTheGateClosed() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _) = try await makeSweptAccount(database: database)
        try await database.dbWriter.write { db in
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [9], flags: [.seen], db: db
            )
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(
            mailboxes: [], statusByPath: [:],
            failConnection: .connectionFailed(underlyingDescription: "offline")
        )
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }
        // A connection-level failure aborts the whole batch (it doesn't even
        // count as an attempt) — the op is left exactly as it was.
        await #expect(throws: MailTransportError.self) {
            _ = try await processor.replay(account: account, auth: auth)
        }

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchCount(db) }
        #expect(remaining == 1, "still queued")
        #expect(
            try await mailbox(database, inbox.id!).lastUnseenSweepAt != nil,
            "so its UIDs are still guarded and there is nothing new to measure"
        )
    }
}
