import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

/// 「ゴミ箱を空にする」— `OpQueueProcessor`'s replay half of `.emptyTrash`:
/// a single `STORE +FLAGS \Deleted` + `EXPUNGE` against the Trash mailbox
/// itself (never a `move` — see `OpQueueKind.emptyTrash`'s doc comment),
/// batching every UID `EmptyTrash.commit` removed into one op rather than
/// one op per message.
@Suite("OpQueueProcessor replay — emptyTrash")
struct OpQueueProcessorEmptyTrashTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
    }

    private let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

    @Test("replay STOREs \\Deleted for every UID then EXPUNGEs the Trash mailbox, never moves")
    func replayStoresAndExpungesTrash() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let trash = try await database.dbWriter.write { db -> MailboxRecord in
            var record = MailboxRecord(accountId: account.id, path: "Trash", displayPath: "Trash", role: .trash, uidValidity: 7)
            try record.insert(db)
            return record
        }

        try await database.dbWriter.write { db in
            try OpQueue.enqueueEmptyTrash(
                accountId: account.id, mailboxId: trash.id!, uidValidity: trash.uidValidity,
                uids: [3, 4, 9], db: db
            )
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)
        #expect(result.affectedMailboxIds.isEmpty)

        let store = try #require(recorder.storeCalls.first)
        #expect(store.path == "Trash")
        #expect(Set(store.change.uids.uids) == [3, 4, 9])
        #expect(store.change.op == .add)
        #expect(store.change.flags == .deleted)

        #expect(recorder.expungeCalls == ["Trash"])
        #expect(recorder.moveCalls.isEmpty)

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchCount(db) }
        #expect(remaining == 0)
    }

    @Test("replay discards an emptyTrash op whose uidValidity no longer matches the mailbox")
    func replayDiscardsStaleUidValidity() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let trash = try await database.dbWriter.write { db -> MailboxRecord in
            var record = MailboxRecord(accountId: account.id, path: "Trash", displayPath: "Trash", role: .trash, uidValidity: 7)
            try record.insert(db)
            return record
        }

        try await database.dbWriter.write { db in
            try OpQueue.enqueueEmptyTrash(
                accountId: account.id, mailboxId: trash.id!, uidValidity: 999,
                uids: [3], db: db
            )
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 0)
        #expect(result.discardedStale == 1)
        #expect(recorder.storeCalls.isEmpty)
        #expect(recorder.expungeCalls.isEmpty)
    }
}
