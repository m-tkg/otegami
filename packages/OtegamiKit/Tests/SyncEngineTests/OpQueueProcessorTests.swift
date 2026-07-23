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

    /// Inserts an account plus an INBOX (and, unless `withTrash` is
    /// `false`, a Trash-role mailbox) directly — `OpQueueProcessor` only
    /// ever reads mailbox rows to resolve a path/uidValidity, so tests
    /// don't need a real sync pass to set this up.
    private func makeAccountWithMailboxes(
        database: AppDatabase,
        inboxUidValidity: Int64 = 1,
        withTrash: Bool = true
    ) async throws -> (account: AccountRecord, inbox: MailboxRecord, trash: MailboxRecord?) {
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let (inbox, trash) = try await database.dbWriter.write { db -> (MailboxRecord, MailboxRecord?) in
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
            return (inboxRecord, trashRecord)
        }
        return (account, inbox, trash)
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
        let (account, inbox, _) = try await makeAccountWithMailboxes(database: database)
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
        let (account, inbox, _) = try await makeAccountWithMailboxes(database: database)

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
        let (account, inbox, _) = try await makeAccountWithMailboxes(database: database, inboxUidValidity: 5)

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
        let (account, inbox, trash) = try await makeAccountWithMailboxes(database: database)

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

    // MARK: attempts ceiling

    @Test("an op that keeps failing stops being retried once it reaches maxAttempts")
    func opStopsRetryingAfterMaxAttempts() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, inbox, _) = try await makeAccountWithMailboxes(database: database)

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
    func fetchEnvelopes(mailboxPath: String, uids: UIDRange, batchSize: Int) async throws -> [FetchedEnvelope] { [] }
    func fetchEnvelopes(mailboxPath: String, changedSince modSeq: UInt64) async throws -> [FetchedEnvelope] { [] }
    func fetchBody(mailboxPath: String, uid: UInt32) async throws -> MessageBodyContent { MessageBodyContent() }
    func fetchMessageBody(mailboxPath: String, uid: UInt32, partId: String?) async throws -> Data { Data() }
    func store(mailboxPath: String, change: FlagChange) async throws {
        throw MailTransportError.serverError(underlyingDescription: "NO (simulated per-op rejection)")
    }
    func append(mailboxPath: String, messageData: Data, flags: MessageFlags) async throws -> UInt32? { nil }
    func move(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {}
    func expunge(mailboxPath: String) async throws {}
    nonisolated func idle(mailboxPath: String) -> AsyncThrowingStream<IdleEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
