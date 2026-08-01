import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

@Suite("OpQueueProcessor replay — outbox attachments")
struct OpQueueProcessorAttachmentTests {
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

    @discardableResult
    private func insertOutboxMessage(accountId: String, database: AppDatabase) async throws -> OutboxMessageRecord {
        try await database.dbWriter.write { db in
            var outbox = OutboxMessageRecord(
                accountId: accountId,
                toAddresses: [EmailAddress(address: "bob@otegami.test")],
                subject: "Hello from the test",
                plainTextBody: "Hi Bob."
            )
            try outbox.insert(db)
            return outbox
        }
    }

    // MARK: M8 — outbox attachments

    /// Writes `data` to a fresh temp file and inserts an `outboxAttachment`
    /// row pointing at it — stands in for `ComposerView.send`'s "copy the
    /// picked file into Application Support/Outbox/, then insert a row"
    /// step without needing a real `AppEnvironment`/UI.
    @discardableResult
    private func insertOutboxAttachment(
        outboxMessageId: Int64,
        filename: String,
        mimeType: String,
        data: Data,
        database: AppDatabase
    ) async throws -> (record: OutboxAttachmentRecord, path: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url)

        let record = try await database.dbWriter.write { db -> OutboxAttachmentRecord in
            var attachment = OutboxAttachmentRecord(
                outboxMessageId: outboxMessageId, filename: filename, mimeType: mimeType,
                localPath: url.path, size: data.count
            )
            try attachment.insert(db)
            return attachment
        }
        return (record, url.path)
    }

    @Test("replay builds the draft's attachments from outboxAttachment rows, reading bytes from disk")
    func replayIncludesOutboxAttachments() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database, account: makeAccountWithSMTP())
        let outbox = try await insertOutboxMessage(accountId: account.id, database: database)
        let payload = Data("fake pdf bytes".utf8)
        let (_, path) = try await insertOutboxAttachment(
            outboxMessageId: outbox.id!, filename: "invoice.pdf", mimeType: "application/pdf",
            data: payload, database: database
        )

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outbox.id!, db: db)
        }

        final class DraftRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var _drafts: [ComposeDraft] = []
            func record(_ draft: ComposeDraft) {
                lock.lock(); _drafts.append(draft); lock.unlock()
            }
            var drafts: [ComposeDraft] {
                lock.lock(); defer { lock.unlock() }; return _drafts
            }
        }
        let draftRecorder = DraftRecorder()
        let recordingBuilder: @Sendable (ComposeDraft) -> BuiltMessage = { draft in
            draftRecorder.record(draft)
            return BuiltMessage(data: Data("fake rfc822".utf8), messageId: "<fake@otegami.local>")
        }

        let smtpRecorder = FakeSMTPSession.CallRecorder()
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script(), recorder: nil) },
            smtpSessionFactory: { config in FakeSMTPSession(config: config, script: FakeSMTPSession.Script(), recorder: smtpRecorder) },
            messageBuilder: recordingBuilder
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)

        let draft = try #require(draftRecorder.drafts.first)
        #expect(draft.attachments.count == 1)
        #expect(draft.attachments.first?.filename == "invoice.pdf")
        #expect(draft.attachments.first?.mimeType == "application/pdf")
        #expect(draft.attachments.first?.data == payload)

        // Best-effort cleanup after a successful send: both the DB row
        // (cascaded from outboxMessage's delete) and the staged file itself.
        let remainingAttachments = try await database.dbWriter.read { db in try OutboxAttachmentRecord.fetchAll(db) }
        #expect(remainingAttachments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("a missing outboxAttachment file is skipped rather than failing the whole send")
    func replaySkipsMissingAttachmentFile() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database, account: makeAccountWithSMTP())
        let outbox = try await insertOutboxMessage(accountId: account.id, database: database)

        // Insert a row pointing at a path nothing was ever written to.
        try await database.dbWriter.write { db in
            var attachment = OutboxAttachmentRecord(
                outboxMessageId: outbox.id!, filename: "ghost.txt", mimeType: "text/plain",
                localPath: "/nonexistent/\(UUID().uuidString)/ghost.txt"
            )
            try attachment.insert(db)
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outbox.id!, db: db)
        }

        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script(), recorder: nil) },
            smtpSessionFactory: { config in FakeSMTPSession(config: config, script: FakeSMTPSession.Script(), recorder: nil) },
            messageBuilder: fakeMessageBuilder
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)
    }

    @Test("a send op whose outbox row is already gone is discarded as stale rather than resent")
    func sendDiscardsWhenOutboxRowAlreadyGone() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database, account: makeAccountWithSMTP())

        // Enqueue a send op referencing an outbox id that was never
        // inserted (or already deleted by an earlier successful replay) —
        // simulates a crash between the SMTP send succeeding and the
        // outbox-row delete committing.
        try await database.dbWriter.write { db in
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: 999, db: db)
        }

        let smtpRecorder = FakeSMTPSession.CallRecorder()
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script(), recorder: nil) },
            smtpSessionFactory: { config in FakeSMTPSession(config: config, script: FakeSMTPSession.Script(), recorder: smtpRecorder) },
            messageBuilder: fakeMessageBuilder
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.discardedStale == 1)
        #expect(smtpRecorder.sendCalls.isEmpty)
    }
}
