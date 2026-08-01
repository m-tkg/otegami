import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

@Suite("OpQueueProcessor replay — delete")
struct OpQueueProcessorDeleteTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
    }

    /// Inserts an account plus an INBOX (and, unless `withTrash` is
    /// `false`, a Trash-role mailbox) directly — `OpQueueProcessor` only
    /// ever reads mailbox rows to resolve a path/uidValidity, so tests
    /// don't need a real sync pass to set this up.
    private func makeAccountWithMailboxes(
        database: AppDatabase,
        inboxUidValidity: Int64 = 1,
        withTrash: Bool = true,
        account: AccountRecord? = nil,
        withSent: Bool = false
    ) async throws -> (account: AccountRecord, inbox: MailboxRecord, trash: MailboxRecord?, sent: MailboxRecord?) {
        let account = account ?? makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let (inbox, trash, sent) = try await database.dbWriter.write { db -> (MailboxRecord, MailboxRecord?, MailboxRecord?) in
            var inboxRecord = MailboxRecord(
                accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox,
                uidValidity: inboxUidValidity
            )
            try inboxRecord.insert(db)

            var trashRecord: MailboxRecord?
            if withTrash {
                var record = MailboxRecord(accountId: account.id, path: "Trash", displayPath: "Trash", role: .trash)
                try record.insert(db)
                trashRecord = record
            }

            var sentRecord: MailboxRecord?
            if withSent {
                var record = MailboxRecord(accountId: account.id, path: "Sent", displayPath: "Sent", role: .sent)
                try record.insert(db)
                sentRecord = record
            }
            return (inboxRecord, trashRecord, sentRecord)
        }
        return (account, inbox, trash, sent)
    }

    private let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

    // MARK: delete → Trash resolution

    @Test("replay resolves a delete op to the account's current Trash mailbox and issues a move")
    func replayResolvesDeleteToTrash() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, trash, _) = try await makeAccountWithMailboxes(database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueDelete(
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

        let call = try #require(recorder.moveCalls.first)
        #expect(call.path == "INBOX")
        #expect(call.uids == [9])
        #expect(call.destination == trash?.path)
    }

    @Test("replay self-heals a missing Trash mailbox: CREATE + SUBSCRIBE, then completes the delete against it")
    func replayCreatesTrashWhenNoneExistsAndCompletesTheDelete() async throws {
        // docs/roadmap.md: "Trash メールボックスが存在しないサーバでの Trash
        // 自動作成" — a server that never advertised SPECIAL-USE and has no
        // mailbox literally named Trash used to leave every delete op
        // permanently `mailboxNotFound`; `OpQueueProcessor` now
        // self-heals by creating one before giving up.
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, trash, _) = try await makeAccountWithMailboxes(database: database, withTrash: false)
        #expect(trash == nil)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueDelete(
                accountId: account.id, sourceMailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [9], db: db
            )
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(
            mailboxes: [],
            statusByPath: [:],
            mailboxRevealedAfterCreate: MailboxInfo(
                path: "Trash", displayPath: "Trash", role: .trash, attributes: []
            )
        )
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)
        #expect(recorder.createMailboxCalls == ["Trash"])

        let call = try #require(recorder.moveCalls.first)
        #expect(call.path == "INBOX")
        #expect(call.uids == [9])
        #expect(call.destination == "Trash")

        // The newly created mailbox is now durably known locally too — a
        // *later* delete (or `FailedOperationsView`'s retry) doesn't need
        // to repeat the CREATE.
        let mailboxes = try await database.dbWriter.read { db in
            try MailboxRecord.filter(Column("accountId") == account.id).fetchAll(db)
        }
        #expect(mailboxes.contains { $0.path == "Trash" && $0.role == .trash })
    }

    @Test("replay leaves a delete op pending (not discarded) when Trash auto-create itself fails")
    func replayLeavesDeletePendingWhenTrashCreateFails() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, trash, _) = try await makeAccountWithMailboxes(database: database, withTrash: false)
        #expect(trash == nil)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueDelete(
                accountId: account.id, sourceMailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [9], db: db
            )
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(
            mailboxes: [],
            statusByPath: [:],
            failCreateMailbox: .serverError(underlyingDescription: "NO permission denied")
        )
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 0)
        #expect(result.discardedStale == 0)
        #expect(result.retrying == 1)
        #expect(recorder.createMailboxCalls == ["Trash"])
        #expect(recorder.moveCalls.isEmpty)

        // Still queued (not silently dropped) — the existing
        // `FailedOperationsView` path (or a future replay, once whatever
        // blocked CREATE is fixed) can still complete it.
        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remaining.count == 1)
    }
}
