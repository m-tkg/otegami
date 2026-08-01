import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

@Suite("OpQueueProcessor replay — send")
struct OpQueueProcessorSendTests {
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

    // MARK: Task #124 — 二重送信防止 (idempotency guard + per-account serialization)

    /// Reproduces the actual reported bug's mechanism directly: two
    /// `replay(account:auth:)` calls for the *same* account, overlapping
    /// in time (this app's real call sites — swipe actions, foreground
    /// sync, the IDLE loop, `PendingSendCoordinator`'s countdown finalize —
    /// routinely do exactly this while a `.send` op is pending). Without
    /// `OpQueueProcessor.inFlightAccountIds`, both calls would fetch the
    /// same still-pending `.send` op before either deleted it and both
    /// hand it to SMTP. `async let` here doesn't need any artificial
    /// delay to force the race: an actor only runs one call's synchronous
    /// prefix at a time, so the first call's `inFlightAccountIds.insert`
    /// (which happens before its first `await`) is guaranteed to have run
    /// before the second call's own guard checks it — deterministic, not
    /// timing-dependent.
    @Test("two overlapping replay() calls for the same account send the message exactly once")
    func overlappingReplayCallsSendExactlyOnce() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database, account: makeAccountWithSMTP())
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

        async let first = processor.replay(account: account, auth: auth)
        async let second = processor.replay(account: account, auth: auth)
        let (firstResult, secondResult) = try await (first, second)

        #expect(smtpRecorder.sendCalls.count == 1, "the message must be sent exactly once, not twice")
        #expect(firstResult.succeeded + secondResult.succeeded == 1)

        let remainingOutbox = try await database.dbWriter.read { db in try OutboxMessageRecord.fetchAll(db) }
        #expect(remainingOutbox.isEmpty)
        let remainingOps = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        #expect(remainingOps.isEmpty)
    }

    /// Simulates a process that crashed *after* a previous replay pass
    /// claimed the send (`OutboxMessageRecord.sendStartedAt` already set)
    /// but *before* it could confirm success or failure — the one case a
    /// fresh process (a brand-new `OpQueueProcessor` actor, so
    /// `inFlightAccountIds` starts out empty and can't help here) must
    /// still refuse to blindly resend, since whether the previous attempt
    /// actually reached the SMTP server is unknown. This is the "安全側に
    /// 倒す" behavior Task #124 calls for: no resend, the op stays pending
    /// (surfacing via `FailedOperationsView` once it exhausts its
    /// retries) rather than risking a duplicate delivery.
    @Test("a send already claimed by a prior (crashed) attempt is never resent")
    func alreadyClaimedSendIsNotResent() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database, account: makeAccountWithSMTP())
        let outbox = try await insertOutboxMessage(accountId: account.id, database: database)
        let outboxId = try #require(outbox.id)

        // Simulates the crash: a previous replay pass's claim survived
        // (the row's own doc comment on `sendStartedAt`), but the row was
        // never deleted because the process died before that could
        // happen.
        try await database.dbWriter.write { db in
            guard var row = try OutboxMessageRecord.fetchOne(db, key: outboxId) else { return }
            row.sendStartedAt = Date()
            try row.update(db)
        }

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outboxId, db: db)
        }

        let smtpRecorder = FakeSMTPSession.CallRecorder()
        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script(), recorder: nil) },
            smtpSessionFactory: { config in FakeSMTPSession(config: config, script: FakeSMTPSession.Script(), recorder: smtpRecorder) },
            messageBuilder: fakeMessageBuilder
        )

        let result = try await processor.replay(account: account, auth: auth)
        #expect(result.retrying == 1)
        #expect(smtpRecorder.sendCalls.isEmpty, "must never resend a claim it didn't win")

        // Still pending, still showing "送信待ち" — discarding it (not
        // retrying it forever) is the user's explicit call via
        // `FailedOperationsView`'s 破棄 button once it's surfaced there.
        let remainingOutbox = try await database.dbWriter.read { db in try OutboxMessageRecord.fetchAll(db) }
        #expect(remainingOutbox.count == 1)
        let remainingOps = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
        let sendOp = try #require(remainingOps.first { $0.kind == OpQueueKind.send.rawValue })
        #expect(sendOp.attempts == 1)
    }

    /// A *clean* SMTP failure (the send call throws locally, not a crash)
    /// must still release the claim so a later replay pass can retry
    /// normally — proving the idempotency guard added for Task #124 didn't
    /// regress the pre-existing "SMTP失敗→リトライ" retry path
    /// (`sendFailureRetriesWithoutAbortingBatch` above covers the first
    /// failed pass; this covers the second, successful one).
    @Test("a clean SMTP failure releases the claim so the next replay pass can send successfully")
    func cleanSMTPFailureAllowsSubsequentRetryToSucceed() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _, _, _) = try await makeAccountWithMailboxes(database: database, account: makeAccountWithSMTP())
        let outbox = try await insertOutboxMessage(accountId: account.id, database: database)

        try await database.dbWriter.write { db in
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outbox.id!, db: db)
        }

        let failingSMTPScript = FakeSMTPSession.Script(failSend: .serverError(underlyingDescription: "temporary failure"))
        let failingProcessor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script(), recorder: nil) },
            smtpSessionFactory: { config in FakeSMTPSession(config: config, script: failingSMTPScript) },
            messageBuilder: fakeMessageBuilder
        )
        let firstResult = try await failingProcessor.replay(account: account, auth: auth)
        #expect(firstResult.retrying == 1)

        let afterFailure = try await database.dbWriter.read { db in try OutboxMessageRecord.fetchOne(db, key: outbox.id!) }
        #expect(afterFailure?.sendStartedAt == nil, "a clean failure must release the claim, not leave it stuck")

        // Clear the backoff window so the retry is immediately due, same
        // as `sendFailureRetriesWithoutAbortingBatch`'s own pattern.
        try await database.dbWriter.write { db in
            try db.execute(sql: "UPDATE opQueue SET nextRetryAt = NULL")
        }

        let smtpRecorder = FakeSMTPSession.CallRecorder()
        let succeedingProcessor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script(), recorder: nil) },
            smtpSessionFactory: { config in FakeSMTPSession(config: config, script: FakeSMTPSession.Script(), recorder: smtpRecorder) },
            messageBuilder: fakeMessageBuilder
        )
        let secondResult = try await succeedingProcessor.replay(account: account, auth: auth)
        #expect(secondResult.succeeded == 1)
        #expect(smtpRecorder.sendCalls.count == 1)

        let remainingOutbox = try await database.dbWriter.read { db in try OutboxMessageRecord.fetchAll(db) }
        #expect(remainingOutbox.isEmpty)
    }

}
