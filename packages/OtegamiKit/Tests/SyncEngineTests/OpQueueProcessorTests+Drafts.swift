import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

@Suite("OpQueueProcessor replay — drafts")
struct OpQueueProcessorDraftsTests {
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

    // MARK: Drafts IMAP sync

    @discardableResult
    private func insertDraftsMailbox(accountId: String, uidValidity: Int64 = 1, database: AppDatabase) async throws -> MailboxRecord {
        try await database.dbWriter.write { db in
            var record = MailboxRecord(accountId: accountId, path: "Drafts", displayPath: "Drafts", role: .drafts, uidValidity: uidValidity)
            try record.insert(db)
            return record
        }
    }

    @discardableResult
    private func insertDraftMessage(
        accountId: String,
        serverMailboxId: Int64? = nil,
        serverUid: Int64? = nil,
        serverUidValidity: Int64? = nil,
        database: AppDatabase
    ) async throws -> DraftMessageRecord {
        try await database.dbWriter.write { db in
            var draft = DraftMessageRecord(
                accountId: accountId,
                toAddresses: [EmailAddress(address: "bob@otegami.test")],
                subject: "Draft subject",
                plainTextBody: "Draft body.",
                serverMailboxId: serverMailboxId,
                serverUid: serverUid,
                serverUidValidity: serverUidValidity
            )
            try draft.insert(db)
            return draft
        }
    }

    @Test("replay APPENDs a new draft to the Drafts mailbox with the \\Draft flag and records the server ref")
    func replaySaveDraftAppendsAndRecordsServerRef() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database)
        let drafts = try await insertDraftsMailbox(accountId: account.id, uidValidity: 7, database: database)
        let draft = try await insertDraftMessage(accountId: account.id, database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSaveDraft(accountId: account.id, draftMessageId: draft.id!, db: db)
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:], appendReturnsUID: 501)
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: script, recorder: recorder) },
            messageBuilder: fakeMessageBuilder
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)

        let appendCall = try #require(recorder.appendCalls.first)
        #expect(appendCall.path == drafts.path)
        #expect(appendCall.flags == .draft)
        #expect(recorder.storeCalls.isEmpty) // nothing to replace
        #expect(recorder.expungeCalls.isEmpty)

        let updated = try await database.dbWriter.read { db in try DraftMessageRecord.fetchOne(db, key: draft.id!) }
        #expect(updated?.serverMailboxId == drafts.id)
        #expect(updated?.serverUid == 501)
        #expect(updated?.serverUidValidity == 7)

        let remainingOps = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remainingOps.isEmpty)
    }

    @Test("replay replaces the previous server copy (\\Deleted + EXPUNGE) when uidValidity still matches")
    func replaySaveDraftReplacesPreviousCopy() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database)
        let drafts = try await insertDraftsMailbox(accountId: account.id, uidValidity: 7, database: database)
        let draft = try await insertDraftMessage(
            accountId: account.id, serverMailboxId: drafts.id!, serverUid: 10, serverUidValidity: 7, database: database
        )

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSaveDraft(accountId: account.id, draftMessageId: draft.id!, db: db)
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:], appendReturnsUID: 501)
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: script, recorder: recorder) },
            messageBuilder: fakeMessageBuilder
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)

        let storeCall = try #require(recorder.storeCalls.first)
        #expect(storeCall.path == drafts.path)
        #expect(storeCall.change.uids.uids == [10])
        #expect(storeCall.change.op == .add)
        #expect(storeCall.change.flags == .deleted)
        #expect(recorder.expungeCalls == [drafts.path])

        let updated = try await database.dbWriter.read { db in try DraftMessageRecord.fetchOne(db, key: draft.id!) }
        #expect(updated?.serverUid == 501, "the row now points at the newly-APPENDed copy, not the deleted one")
    }

    @Test("replay skips replacing the old copy (but still appends the new one) when the old uidValidity is stale")
    func replaySaveDraftSkipsStaleOldCopy() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database)
        let drafts = try await insertDraftsMailbox(accountId: account.id, uidValidity: 7, database: database)
        // `serverUidValidity: 99` no longer matches the mailbox's current 7
        // (e.g. the Drafts mailbox was recreated since this ref was
        // captured) — the old UID may not even refer to this draft
        // anymore, so cleanup must be skipped outright, not misapplied.
        let draft = try await insertDraftMessage(
            accountId: account.id, serverMailboxId: drafts.id!, serverUid: 10, serverUidValidity: 99, database: database
        )

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSaveDraft(accountId: account.id, draftMessageId: draft.id!, db: db)
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:], appendReturnsUID: 501)
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: script, recorder: recorder) },
            messageBuilder: fakeMessageBuilder
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)
        #expect(recorder.storeCalls.isEmpty, "no attempt to delete the stale-uidValidity old copy")
        #expect(recorder.expungeCalls.isEmpty)
        #expect(recorder.appendCalls.count == 1, "the new copy is still appended")

        let updated = try await database.dbWriter.read { db in try DraftMessageRecord.fetchOne(db, key: draft.id!) }
        #expect(updated?.serverUid == 501)
        #expect(updated?.serverUidValidity == 7)
    }

    @Test("a saveDraft op whose draftMessage row is already gone is discarded as stale")
    func replaySaveDraftDiscardsWhenRowGone() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database)
        try await insertDraftsMailbox(accountId: account.id, database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSaveDraft(accountId: account.id, draftMessageId: 999, db: db)
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script(), recorder: recorder) },
            messageBuilder: fakeMessageBuilder
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.discardedStale == 1)
        #expect(recorder.appendCalls.isEmpty)
    }

    /// Mirrors `replayIncludesOutboxAttachments` for `draftAttachment`.
    @discardableResult
    private func insertDraftAttachment(
        draftMessageId: Int64, filename: String, mimeType: String, data: Data, database: AppDatabase
    ) async throws -> (record: DraftAttachmentRecord, path: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url)

        let record = try await database.dbWriter.write { db -> DraftAttachmentRecord in
            var attachment = DraftAttachmentRecord(
                draftMessageId: draftMessageId, filename: filename, mimeType: mimeType, localPath: url.path, size: data.count
            )
            try attachment.insert(db)
            return attachment
        }
        return (record, url.path)
    }

    @Test("replay builds the draft's attachments from draftAttachment rows, reading bytes from disk")
    func replaySaveDraftIncludesAttachments() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database)
        try await insertDraftsMailbox(accountId: account.id, database: database)
        let draft = try await insertDraftMessage(accountId: account.id, database: database)
        let payload = Data("fake pdf bytes".utf8)
        try await insertDraftAttachment(
            draftMessageId: draft.id!, filename: "invoice.pdf", mimeType: "application/pdf", data: payload, database: database
        )

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSaveDraft(accountId: account.id, draftMessageId: draft.id!, db: db)
        }

        final class DraftRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var _drafts: [ComposeDraft] = []
            func record(_ draft: ComposeDraft) { lock.lock(); _drafts.append(draft); lock.unlock() }
            var drafts: [ComposeDraft] { lock.lock(); defer { lock.unlock() }; return _drafts }
        }
        let draftRecorder = DraftRecorder()
        let recordingBuilder: @Sendable (ComposeDraft) -> BuiltMessage = { composeDraft in
            draftRecorder.record(composeDraft)
            return BuiltMessage(data: Data("fake rfc822".utf8), messageId: "<fake@otegami.local>")
        }

        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script(), recorder: nil) },
            messageBuilder: recordingBuilder
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)

        let composed = try #require(draftRecorder.drafts.first)
        #expect(composed.attachments.count == 1)
        #expect(composed.attachments.first?.filename == "invoice.pdf")
        #expect(composed.attachments.first?.data == payload)
    }

    @Test("replay resolves a saveDraft op to a self-healed Drafts mailbox when none is known yet")
    func replaySaveDraftSelfHealsMissingDraftsMailbox() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database)
        let draft = try await insertDraftMessage(accountId: account.id, database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSaveDraft(accountId: account.id, draftMessageId: draft.id!, db: db)
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let revealed = MailboxInfo(path: "Drafts", displayPath: "Drafts", role: .drafts, attributes: [])
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:], mailboxRevealedAfterCreate: revealed, appendReturnsUID: 1)
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: script, recorder: recorder) },
            messageBuilder: fakeMessageBuilder
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)
        #expect(recorder.createMailboxCalls == ["Drafts"])
        #expect(recorder.appendCalls.first?.path == "Drafts")
    }

    @Test("replay applies a queued deleteDraft op (\\Deleted + EXPUNGE) and removes it from the queue")
    func replayDeleteDraftIssuesStoreAndExpunge() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database)
        let drafts = try await insertDraftsMailbox(accountId: account.id, uidValidity: 3, database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueDeleteDraft(accountId: account.id, mailboxId: drafts.id!, uidValidity: 3, uid: 77, db: db)
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script(), recorder: recorder) }
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)

        let storeCall = try #require(recorder.storeCalls.first)
        #expect(storeCall.path == drafts.path)
        #expect(storeCall.change.uids.uids == [77])
        #expect(storeCall.change.flags == .deleted)
        #expect(recorder.expungeCalls == [drafts.path])

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remaining.isEmpty)
    }

    @Test("replay discards a deleteDraft op whose uidValidity no longer matches the mailbox")
    func replayDeleteDraftDiscardsStale() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database)
        let drafts = try await insertDraftsMailbox(accountId: account.id, uidValidity: 3, database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueDeleteDraft(accountId: account.id, mailboxId: drafts.id!, uidValidity: 1, uid: 77, db: db)
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script(), recorder: recorder) }
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.discardedStale == 1)
        #expect(recorder.storeCalls.isEmpty)
        #expect(recorder.expungeCalls.isEmpty)
    }

    @Test("replay best-effort deletes a send's linked Drafts copy after the message is successfully sent")
    func replaySendDeletesLinkedDraft() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, sent) = try await makeAccountWithMailboxes(
            database: database, account: makeAccountWithSMTP(), withSent: true
        )
        let drafts = try await insertDraftsMailbox(accountId: account.id, uidValidity: 4, database: database)

        let outbox = try await database.dbWriter.write { db -> OutboxMessageRecord in
            var outbox = OutboxMessageRecord(
                accountId: account.id,
                toAddresses: [EmailAddress(address: "bob@otegami.test")],
                subject: "Hello from a draft",
                plainTextBody: "Hi Bob.",
                draftServerMailboxId: drafts.id!,
                draftServerUid: 55,
                draftServerUidValidity: 4
            )
            try outbox.insert(db)
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outbox.id!, db: db)
            return outbox
        }
        _ = outbox

        let imapRecorder = FakeIMAPSession.CallRecorder()
        let imapScript = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: imapScript, recorder: imapRecorder) },
            smtpSessionFactory: { config in FakeSMTPSession(config: config, script: FakeSMTPSession.Script(), recorder: nil) },
            messageBuilder: fakeMessageBuilder
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)

        // Both the Sent-mailbox append and the Drafts-mailbox cleanup
        // happen — distinguish them by path.
        #expect(imapRecorder.appendCalls.contains { $0.path == sent?.path })
        let draftDeleteCall = try #require(imapRecorder.storeCalls.first { $0.path == drafts.path })
        #expect(draftDeleteCall.change.uids.uids == [55])
        #expect(draftDeleteCall.change.flags == .deleted)
        #expect(imapRecorder.expungeCalls.contains(drafts.path))
    }
}
