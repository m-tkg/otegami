import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

@Suite("OpQueueProcessor replay — ReplayResult.affectedMailboxIds")
struct OpQueueProcessorAffectedMailboxIdsTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
    }

    /// M5: a `makeAccount()`-equivalent with SMTP fields filled in — `.send`
    /// replay discards the op outright (no SMTP to retry toward) when
    /// `AccountRecord.smtpConfig` is `nil`, so send-specific tests need this
    /// instead of the bare `makeAccount()`.
    private func makeAccountWithSMTP() -> AccountRecord {
        AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test",
            smtpHost: "localhost", smtpPort: 1025, smtpSecurity: .plain, smtpUsername: "test1@otegami.test"
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

    private let fakeMessageBuilder: @Sendable (ComposeDraft) -> BuiltMessage = { draft in
        BuiltMessage(data: Data("fake rfc822 for \(draft.subject)".utf8), messageId: "<fake-\(draft.subject)@otegami.local>")
    }

    // MARK: - Task #152: ReplayResult.affectedMailboxIds

    @Test("ReplayResult.affectedMailboxIds reports just the mailbox a setFlags op touched")
    func replayResultAffectedMailboxIdsForSetFlags() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database)
        try await database.dbWriter.write { db in
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [42], flags: .seen, db: db
            )
        }
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script())
        }

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)
        #expect(result.affectedMailboxIds == [inbox.id!])
    }

    @Test("ReplayResult.affectedMailboxIds reports both the source and self-healed destination for an archive op")
    func replayResultAffectedMailboxIdsForArchive() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database)
        let archiveId = try await database.dbWriter.write { db -> Int64 in
            var record = MailboxRecord(accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive)
            try record.insert(db)
            try OpQueue.enqueueArchive(
                accountId: account.id, sourceMailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [9], db: db
            )
            return record.id!
        }
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script())
        }

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)
        #expect(result.affectedMailboxIds == Set([inbox.id!, archiveId]))
    }

    @Test("ReplayResult.affectedMailboxIds reports both mailboxes for a plain move op")
    func replayResultAffectedMailboxIdsForMove() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database)
        let otherId = try await database.dbWriter.write { db -> Int64 in
            var record = MailboxRecord(accountId: account.id, path: "Other", displayPath: "Other", role: .none)
            try record.insert(db)
            try OpQueue.enqueueMove(
                accountId: account.id, sourceMailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [3], destinationMailboxId: record.id!, db: db
            )
            return record.id!
        }
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script())
        }

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)
        #expect(result.affectedMailboxIds == Set([inbox.id!, otherId]))
    }

    @Test("ReplayResult.affectedMailboxIds is empty for a discarded (stale) op")
    func replayResultAffectedMailboxIdsEmptyForStaleDiscard() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database)
        try await database.dbWriter.write { db in
            // A `uidValidity` that no longer matches `inbox.uidValidity` —
            // discarded as stale rather than applied.
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity + 1,
                uids: [42], flags: .seen, db: db
            )
        }
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script())
        }

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 0)
        #expect(result.discardedStale == 1)
        #expect(result.affectedMailboxIds.isEmpty)
    }

    @Test("ReplayResult.affectedMailboxIds does not include a .send op's outbox/SMTP plumbing")
    func replayResultAffectedMailboxIdsEmptyForSend() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database, account: makeAccountWithSMTP())
        let outbox = try await database.dbWriter.write { db -> OutboxMessageRecord in
            var outbox = OutboxMessageRecord(
                accountId: account.id, toAddresses: [EmailAddress(address: "recipient@otegami.test")],
                subject: "件名", plainTextBody: "本文"
            )
            try outbox.insert(db)
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outbox.id!, db: db)
            return outbox
        }
        _ = outbox

        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script()) },
            smtpSessionFactory: { config in FakeSMTPSession(config: config, script: FakeSMTPSession.Script(), recorder: nil) },
            messageBuilder: fakeMessageBuilder
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)
        #expect(result.affectedMailboxIds.isEmpty, "send/saveDraft/deleteDraft are outside Task #152's targeted-resync scope — see ReplayResult.affectedMailboxIds's doc comment")
    }
}
