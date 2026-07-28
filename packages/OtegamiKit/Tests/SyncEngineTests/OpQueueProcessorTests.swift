import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

@Suite("OpQueueProcessor replay")
struct OpQueueProcessorTests {
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

    /// Inserts a bare `message` row so a test can assert on local state
    /// (e.g. that the flags an offline action already applied locally are
    /// what `replay` mirrors to the server) without going through a full
    /// sync pass.
    @discardableResult
    private func insertMessage(mailboxId: Int64, uid: Int64, flags: MessageFlags, database: AppDatabase) async throws -> MessageRecord {
        try await database.dbWriter.write { db in
            var message = MessageRecord(mailboxId: mailboxId, uid: uid, internalDate: Date(), flagsRaw: flags.rawValue)
            try message.insert(db)
            return message
        }
    }

    private let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

    // MARK: (e) offline enqueue → replay succeeds once reconnected

    @Test("replay applies a queued setFlags op to the server and removes it from the queue")
    func replayAppliesSetFlags() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database)
        let messageId = try await insertMessage(mailboxId: inbox.id!, uid: 42, flags: [], database: database).id!

        // Simulate the offline UI flow: local flag update + enqueue,
        // committed together (MessageView/MessageListView's pattern).
        try await database.dbWriter.write { db in
            var message = try MessageRecord.fetchOne(db, key: messageId)!
            message.flags.insert(.seen)
            try message.update(db)
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [42], flags: message.flags, db: db
            )
        }

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)
        #expect(result.discardedStale == 0)

        #expect(recorder.storeCalls.count == 1)
        let call = try #require(recorder.storeCalls.first)
        #expect(call.path == "INBOX")
        #expect(call.change.uids.uids == [42])
        #expect(call.change.op == .replace)
        #expect(call.change.flags == .seen)

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remaining.isEmpty)
    }

    // MARK: (d) idempotent replay, generation-mismatch discard

    @Test("replaying the same absolute-flags op twice issues the same STORE each time (idempotent)")
    func replayIsIdempotent() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database)

        let recorder = FakeIMAPSession.CallRecorder()
        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        }

        // Enqueue, replay, then enqueue an *identical* op again (as if the
        // same UI action fired twice, or a retry re-enqueued it) and
        // replay again.
        for _ in 0..<2 {
            try await database.dbWriter.write { db in
                try OpQueue.enqueueSetFlags(
                    accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                    uids: [7], flags: .seen, db: db
                )
            }
            let result = try await processor.replay(account: account, auth: auth)
            #expect(result.succeeded == 1)
        }

        #expect(recorder.storeCalls.count == 2)
        // Same absolute flags both times — replaying twice converges to
        // the same server-side state rather than compounding.
        #expect(recorder.storeCalls.allSatisfy { $0.change.flags == .seen && $0.change.op == .replace })

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remaining.isEmpty)
    }

    @Test("replay discards an op whose uidValidity no longer matches the mailbox")
    func replayDiscardsStaleGeneration() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database, inboxUidValidity: 5)

        try await database.dbWriter.write { db in
            // Enqueued against uidValidity 1 (an older generation than the
            // mailbox's current 5 — e.g. the mailbox was recreated between
            // enqueue and replay).
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: 1,
                uids: [42], flags: .seen, db: db
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

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remaining.isEmpty)
    }

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

    // MARK: attempts ceiling

    @Test("an op that keeps failing stops being retried once it reaches maxAttempts")
    func opStopsRetryingAfterMaxAttempts() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [1], flags: .seen, db: db
            )
        }

        let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let processor = OpQueueProcessor(database: database) { config in
            FailingStoreSession(config: config, script: script)
        }

        var lastResult = OpQueueProcessor.ReplayResult()
        for _ in 0..<OpQueueProcessor.maxAttempts {
            // Bypass backoff between attempts for the test — directly
            // clear nextRetryAt rather than waiting real wall-clock time.
            try await database.dbWriter.write { db in
                try db.execute(sql: "UPDATE opQueue SET nextRetryAt = NULL")
            }
            lastResult = try await processor.replay(account: account, auth: auth)
        }

        #expect(lastResult.permanentlyFailed == 1)

        let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        let op = try #require(remaining.first)
        #expect(op.attempts == OpQueueProcessor.maxAttempts)

        // A further replay call doesn't even try it (attempts >= maxAttempts
        // is filtered out before a connection is opened).
        try await database.dbWriter.write { db in
            try db.execute(sql: "UPDATE opQueue SET nextRetryAt = NULL")
        }
        let finalResult = try await processor.replay(account: account, auth: auth)
        #expect(finalResult.succeeded == 0)
        #expect(finalResult.retrying == 0)
        #expect(finalResult.permanentlyFailed == 0)
    }

    // MARK: M5 — send

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

    @Test("replay sends a queued message via SMTP, appends a copy to Sent, and removes the outbox row + op")
    func replaySendsMessageAndAppendsToSent() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, sent) = try await makeAccountWithMailboxes(
            database: database, account: makeAccountWithSMTP(), withSent: true
        )
        let outbox = try await insertOutboxMessage(accountId: account.id, database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outbox.id!, db: db)
        }

        let imapRecorder = FakeIMAPSession.CallRecorder()
        let imapScript = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
        let smtpRecorder = FakeSMTPSession.CallRecorder()
        let smtpScript = FakeSMTPSession.Script()
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: imapScript, recorder: imapRecorder) },
            smtpSessionFactory: { config in FakeSMTPSession(config: config, script: smtpScript, recorder: smtpRecorder) },
            messageBuilder: fakeMessageBuilder
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)

        let sendCall = try #require(smtpRecorder.sendCalls.first)
        #expect(sendCall.from.address == account.email)
        #expect(sendCall.recipients.map(\.address) == ["bob@otegami.test"])

        let appendCall = try #require(imapRecorder.appendCalls.first)
        #expect(appendCall.path == sent?.path)
        #expect(appendCall.flags == .seen)

        let remainingOutbox = try await database.dbWriter.read { db in try OutboxMessageRecord.fetchAll(db) }
        #expect(remainingOutbox.isEmpty)
        let remainingOps = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remainingOps.isEmpty)
    }

    @Test("replay skips the Sent APPEND for a Gmail-kind account")
    func replaySkipsSentAppendForGmailAccount() async throws {
        let database = try AppDatabase.makeInMemory()
        var gmailAccount = makeAccountWithSMTP()
        gmailAccount.kind = .gmail
        let (account, _, _, _) = try await makeAccountWithMailboxes(
            database: database, account: gmailAccount, withSent: true
        )
        let outbox = try await insertOutboxMessage(accountId: account.id, database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outbox.id!, db: db)
        }

        let imapRecorder = FakeIMAPSession.CallRecorder()
        let smtpRecorder = FakeSMTPSession.CallRecorder()
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script(), recorder: imapRecorder) },
            smtpSessionFactory: { config in FakeSMTPSession(config: config, script: FakeSMTPSession.Script(), recorder: smtpRecorder) },
            messageBuilder: fakeMessageBuilder
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)
        #expect(smtpRecorder.sendCalls.count == 1)
        #expect(imapRecorder.appendCalls.isEmpty)

        let remainingOutbox = try await database.dbWriter.read { db in try OutboxMessageRecord.fetchAll(db) }
        #expect(remainingOutbox.isEmpty)
    }

    @Test("an SMTP send failure leaves the send op queued for retry rather than aborting the whole replay batch")
    func sendFailureRetriesWithoutAbortingBatch() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _, _) = try await makeAccountWithMailboxes(
            database: database, account: makeAccountWithSMTP(), withSent: true
        )
        let outbox = try await insertOutboxMessage(accountId: account.id, database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outbox.id!, db: db)
            // An unrelated setFlags op in the same batch, sharing the IMAP
            // session — must still succeed even though the SMTP send below
            // fails, proving the SMTP failure doesn't get reclassified as
            // connection-level (which would abort the whole batch).
            try OpQueue.enqueueSetFlags(
                accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                uids: [1], flags: .seen, db: db
            )
        }

        let imapRecorder = FakeIMAPSession.CallRecorder()
        let smtpScript = FakeSMTPSession.Script(failSend: .serverError(underlyingDescription: "550 simulated rejection"))
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script(), recorder: imapRecorder) },
            smtpSessionFactory: { config in FakeSMTPSession(config: config, script: smtpScript) },
            messageBuilder: fakeMessageBuilder
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1) // the unrelated setFlags op
        #expect(result.retrying == 1) // the failed send op

        #expect(imapRecorder.storeCalls.count == 1) // setFlags still went through

        let remainingOutbox = try await database.dbWriter.read { db in try OutboxMessageRecord.fetchAll(db) }
        #expect(remainingOutbox.count == 1) // never deleted — still "送信待ち"

        let remainingOps = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        let sendOp = try #require(remainingOps.first { $0.kind == OpQueueKind.send.rawValue })
        #expect(sendOp.attempts == 1)
    }

    @Test("send derives SMTP auth from account.smtpUsername, not the IMAP auth's username — blank means no auth")
    func sendUsesSMTPSpecificAuthNotIMAPAuth() async throws {
        let database = try AppDatabase.makeInMemory()
        // smtpUsername left nil (blank in the form) — imapUsername stays
        // "test1@otegami.test" from makeAccountWithSMTP()'s IMAP fields,
        // deliberately different so a bug that reused the IMAP auth
        // verbatim would be caught by asserting an *empty* SMTP username
        // below, not just a matching one.
        var blankSMTPUsernameAccount = makeAccountWithSMTP()
        blankSMTPUsernameAccount.smtpUsername = nil
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database, account: blankSMTPUsernameAccount)
        let outbox = try await insertOutboxMessage(accountId: account.id, database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outbox.id!, db: db)
        }

        let smtpRecorder = FakeSMTPSession.CallRecorder()
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script(), recorder: nil) },
            smtpSessionFactory: { config in FakeSMTPSession(config: config, script: FakeSMTPSession.Script(), recorder: smtpRecorder) },
            messageBuilder: fakeMessageBuilder
        )

        // `auth` here (what replay() opens the IMAP session with) carries
        // the non-blank IMAP username — the whole point of this test is
        // that it must NOT leak into the SMTP connect call below.
        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.succeeded == 1)

        let connectAuth = try #require(smtpRecorder.connectAuths.first)
        guard case .password(let username, _) = connectAuth else {
            Issue.record("Expected a .password SMTP auth")
            return
        }
        #expect(username.isEmpty, "Expected a blank SMTP username (no smtpUsername configured), not the IMAP auth's username")
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
        #expect(recorder.createMailboxCalls == [OpQueueProcessor.draftsMailboxNameToCreate])
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

/// A minimal `IMAPSessionProtocol` double, separate from `FakeIMAPSession`,
/// whose `store` always fails with a per-op (not connection-level) error —
/// used to test `OpQueueProcessor`'s `maxAttempts` failure ceiling without
/// tripping the connection-level "abort the whole batch" path.
private actor FailingStoreSession: IMAPSessionProtocol {
    private let config: IMAPConfig
    private let script: FakeIMAPSession.Script

    init(config: IMAPConfig) {
        self.config = config
        self.script = FakeIMAPSession.Script()
    }

    init(config: IMAPConfig, script: FakeIMAPSession.Script) {
        self.config = config
        self.script = script
    }

    func connect(auth: MailAuth) async throws {}
    func disconnect() async {}
    func capabilities() async throws -> Set<IMAPCapability> { [] }
    func listMailboxes() async throws -> [MailboxInfo] { [] }
    func select(_ mailboxPath: String) async throws -> MailboxStatus { MailboxStatus(uidValidity: 0, uidNext: 0, highestModSeq: 0, messageCount: 0) }
    func status(_ mailboxPath: String) async throws -> MailboxStatus { MailboxStatus(uidValidity: 0, uidNext: 0, highestModSeq: 0, messageCount: 0) }
    func createMailbox(path: String) async throws {}
    func fetchEnvelopes(mailboxPath: String, uids: UIDRange, batchSize: Int) async throws -> [FetchedEnvelope] { [] }
    func fetchRecentEnvelopes(mailboxPath: String, count: Int, batchSize: Int) async throws -> [FetchedEnvelope] { [] }
    func fetchEnvelopes(mailboxPath: String, changedSince modSeq: UInt64) async throws -> ChangedSinceResult { ChangedSinceResult(envelopes: []) }
    func searchExistingUIDs(mailboxPath: String, uids: UIDRange) async throws -> Set<UInt32> { [] }
    func fetchBody(mailboxPath: String, uid: UInt32) async throws -> MessageBodyContent { MessageBodyContent() }
    func fetchMessageBody(mailboxPath: String, uid: UInt32, partId: String?) async throws -> Data { Data() }
    func store(mailboxPath: String, change: FlagChange) async throws {
        throw MailTransportError.serverError(underlyingDescription: "NO (simulated per-op rejection)")
    }
    func append(mailboxPath: String, messageData: Data, flags: MessageFlags) async throws -> UInt32? { nil }
    func move(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {}
    func copy(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {}
    func expunge(mailboxPath: String) async throws {}
    nonisolated func idle(mailboxPath: String) -> AsyncThrowingStream<IdleEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
