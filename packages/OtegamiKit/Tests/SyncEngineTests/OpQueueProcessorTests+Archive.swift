import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

@Suite("OpQueueProcessor replay — archive / unarchive")
struct OpQueueProcessorArchiveTests {
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

    // MARK: archive → Archive resolution (non-Gmail) / unlabel-in-place (Gmail)

    @Test("replay resolves an archive op to the account's current Archive mailbox and issues a move")
    func replayResolvesArchiveToArchiveMailbox() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database)
        try await database.dbWriter.write { db in
            var record = MailboxRecord(accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive)
            try record.insert(db)
        }

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

        let call = try #require(recorder.moveCalls.first)
        #expect(call.path == "INBOX")
        #expect(call.uids == [9])
        #expect(call.destination == "Archive")
        #expect(recorder.storeCalls.isEmpty)
        #expect(recorder.expungeCalls.isEmpty)
    }

    @Test("replay self-heals a missing Archive mailbox: CREATE, then completes the archive against it")
    func replayCreatesArchiveWhenNoneExistsAndCompletesTheArchive() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueArchive(
                accountId: account.id, sourceMailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [9], db: db
            )
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(
            mailboxes: [],
            statusByPath: [:],
            mailboxRevealedAfterCreate: MailboxInfo(
                path: "Archive", displayPath: "Archive", role: .archive, attributes: []
            )
        )
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)
        #expect(recorder.createMailboxCalls == ["Archive"])

        let call = try #require(recorder.moveCalls.first)
        #expect(call.path == "INBOX")
        #expect(call.uids == [9])
        #expect(call.destination == "Archive")

        let mailboxes = try await database.dbWriter.read { db in
            try MailboxRecord.filter(Column("accountId") == account.id).fetchAll(db)
        }
        #expect(mailboxes.contains { $0.path == "Archive" && $0.role == .archive })
    }

    @Test("replay leaves an archive op pending (not discarded) when Archive auto-create itself fails")
    func replayLeavesArchivePendingWhenArchiveCreateFails() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueArchive(
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
        #expect(result.retrying == 1)
        #expect(recorder.createMailboxCalls == ["Archive"])
        #expect(recorder.moveCalls.isEmpty)

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remaining.count == 1)
    }

    @Test("replay archives a Gmail account's message in place (STORE \\Deleted + EXPUNGE on the source, no move) rather than resolving an Archive mailbox that doesn't exist")
    func replayArchivesGmailAccountInPlace() async throws {
        // Gmail has no `\Archive`-flagged folder — its "All Mail" reports
        // `\All`, mapped to `MailboxRole.all`, not `.archive` (see
        // `OpQueueKind.archive`'s doc comment). This is the regression test
        // for the reported "archive does nothing on Gmail" bug: before this
        // fix, `commitArchive`'s local Archive-role lookup always came back
        // nil for a Gmail account, so the op was never even enqueued.
        let database = try AppDatabase.makeInMemory()
        let gmailAccount = AccountRecord(
            displayName: "Gmail Test", email: "test@gmail.com", authType: .oauth2, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "test@gmail.com"
        )
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database, withTrash: false, account: gmailAccount)

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

        // No CREATE/move attempted at all — Gmail's archive path never
        // tries to resolve a destination mailbox.
        #expect(recorder.createMailboxCalls.isEmpty)
        #expect(recorder.moveCalls.isEmpty)

        let storeCall = try #require(recorder.storeCalls.first)
        #expect(storeCall.path == "INBOX")
        #expect(storeCall.change.uids.uids == [9])
        #expect(storeCall.change.op == .add)
        #expect(storeCall.change.flags == .deleted)

        #expect(recorder.expungeCalls == ["INBOX"])
    }

    // MARK: unarchive → back to INBOX (non-Gmail move) / COPY into INBOX (Gmail)

    @Test("replay resolves an unarchive op back to the account's INBOX mailbox and issues a move")
    func replayResolvesUnarchiveBackToInbox() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database)
        let archiveId = try await database.dbWriter.write { db -> Int64 in
            var record = MailboxRecord(accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive)
            try record.insert(db)
            return record.id!
        }

        try await database.dbWriter.write { db in
            try OpQueue.enqueueUnarchive(
                accountId: account.id, sourceMailboxId: archiveId, uidValidity: 0,
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
        #expect(call.path == "Archive")
        #expect(call.uids == [9])
        #expect(call.destination == "INBOX")
        #expect(recorder.copyCalls.isEmpty)
    }

    @Test("replay restores a Gmail account's INBOX label via COPY (never a move — the message must stay in All Mail too)")
    func replayRestoresGmailInboxLabelViaCopy() async throws {
        // Mirrors `replayArchivesGmailAccountInPlace`'s Gmail setup —
        // Gmail's "All Mail" (role `.all`) is where an archived message
        // actually sits (see `OpQueueKind.unarchive`'s doc comment): a plain
        // `COPY` into INBOX adds the label back without ever touching All
        // Mail, unlike `move` (which would incorrectly pull it out).
        let database = try AppDatabase.makeInMemory()
        let gmailAccount = AccountRecord(
            displayName: "Gmail Test", email: "test@gmail.com", authType: .oauth2, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "test@gmail.com"
        )
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database, withTrash: false, account: gmailAccount)
        let allMailId = try await database.dbWriter.write { db -> Int64 in
            var record = MailboxRecord(accountId: account.id, path: "[Gmail]/All Mail", displayPath: "All Mail", role: .all)
            try record.insert(db)
            return record.id!
        }

        try await database.dbWriter.write { db in
            try OpQueue.enqueueUnarchive(
                accountId: account.id, sourceMailboxId: allMailId, uidValidity: 0,
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

        let call = try #require(recorder.copyCalls.first)
        #expect(call.path == "[Gmail]/All Mail")
        #expect(call.uids == [9])
        #expect(call.destination == "INBOX")
        // Never a move/store+expunge — All Mail must stay untouched.
        #expect(recorder.moveCalls.isEmpty)
        #expect(recorder.storeCalls.isEmpty)
        #expect(recorder.expungeCalls.isEmpty)
    }
}
