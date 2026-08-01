import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

@Suite("OpQueueProcessor replay — retry / attempts ceiling / DB suspension")
struct OpQueueProcessorRetryTests {
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

    // MARK: Task #192 — database suspension (0xDEAD10CC)

    /// A suspended database (GRDB's 0xDEAD10CC-prevention mechanism — see
    /// `DatabaseSuspensionSupport`'s doc comment) failing an op's write must
    /// not be treated as an ordinary per-op failure: `recordFailure(op:
    /// error:)` is itself a `dbWriter.write` call that would fail the exact
    /// same way, and unlike every other call site in `OpQueueProcessor`
    /// it isn't `try?`-wrapped — before this task, that uncaught throw
    /// would propagate out of the per-op `catch` block by accident rather
    /// than by design. This test suspends the *real* in-memory database
    /// (via GRDB's own public `Database.suspendNotification`, not a
    /// hand-built error) partway through `replay`, right after the
    /// scripted IMAP `store` succeeds but before `OpQueueProcessor` deletes
    /// the completed op — exactly the timing window a real background
    /// suspend could land in.
    @Test("a suspended database aborts the replay batch instead of recording a spurious per-op failure")
    func suspendedDatabaseAbortsReplayWithoutRecordingFailure() async throws {
        // `Database.suspendNotification` is process-global (see
        // `DatabaseSuspensionTestLock`'s doc comment) — serialize against
        // every other test in this run that also posts it for real.
        try await DatabaseSuspensionTestLock.withLock {
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            configuration.observesSuspensionNotifications = true
            // File-backed, not `AppDatabase.makeInMemory()`'s in-memory
            // `DatabaseQueue` — GRDB 7.11.1's in-memory init never registers the
            // `Database.suspendNotification`/`.resumeNotification` observers at
            // all (only the file-path init does; see `DatabaseSuspensionTests
            // .makeSuspendableQueue()`'s doc comment in OtegamiStoreTests for
            // the confirmed source-level reason), so posting those notifications
            // against an in-memory queue would be silently inert.
            let dbPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("otegami-opqueue-suspension-test-\(UUID().uuidString).sqlite").path
            let database = try AppDatabase(DatabaseQueue(path: dbPath, configuration: configuration))
            defer { try? FileManager.default.removeItem(atPath: dbPath) }
            let (account, inbox, _, _) = try await makeAccountWithMailboxes(database: database)

            try await database.dbWriter.write { db in
                try OpQueue.enqueueSetFlags(
                    accountId: account.id, mailboxId: inbox.id!, uidValidity: inbox.uidValidity,
                    uids: [1], flags: .seen, db: db
                )
            }

            let script = FakeIMAPSession.Script(mailboxes: [], statusByPath: [:])
            let processor = OpQueueProcessor(database: database) { config in
                SuspendingStoreSession(config: config, script: script) {
                    NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
                }
            }

            do {
                _ = try await processor.replay(account: account, auth: auth)
                Issue.record("expected replay to rethrow the suspension error, matching the connection-level abort path")
            } catch {
                #expect(DatabaseSuspensionSupport.isSuspensionError(error))
            }
            // Resume so this suite's later tests (and this in-memory database's
            // own teardown) aren't left suspended.
            NotificationCenter.default.post(name: Database.resumeNotification, object: nil)

            let remaining = try await database.dbWriter.read { db in try OpQueueRecord.fetchAll(db) }
            let op = try #require(remaining.first, "the op must still be queued — never deleted, never counted as a failed attempt")
            #expect(op.attempts == 0, "a suspension isn't the op's fault; it must not consume any of its maxAttempts budget")
            #expect(op.lastError == nil, "no confusing \"Database is suspended\" text should ever reach FailedOperationsView's banner")
        }
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
    func fetchFlags(mailboxPath: String, uids: UIDRange) async throws -> [UInt32: MessageFlags] { [:] }
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

/// Task #192: another minimal `IMAPSessionProtocol` double, mirroring
/// `FailingStoreSession`'s shape — everything delegates to a real
/// `FakeIMAPSession` except `store`, which succeeds normally and then runs
/// `onStoreSucceeded` (`suspendedDatabaseAbortsReplayWithoutRecordingFailure`
/// posts `Database.suspendNotification` there). This lands the suspension
/// in the precise window `OpQueueProcessor.replay`'s `.setFlags` case needs
/// to observe it: after the fetch-due-ops read and the mailbox lookup read
/// have both already succeeded (so this test actually exercises the per-op
/// `catch` branch, not an earlier, unrelated failure), but before the
/// `delete(op:)` write that normally follows a successful `store`.
private actor SuspendingStoreSession: IMAPSessionProtocol {
    private let underlying: FakeIMAPSession
    private let onStoreSucceeded: @Sendable () -> Void

    init(config: IMAPConfig) {
        self.underlying = FakeIMAPSession(config: config)
        self.onStoreSucceeded = {}
    }

    init(config: IMAPConfig, script: FakeIMAPSession.Script, onStoreSucceeded: @escaping @Sendable () -> Void) {
        self.underlying = FakeIMAPSession(config: config, script: script)
        self.onStoreSucceeded = onStoreSucceeded
    }

    func connect(auth: MailAuth) async throws { try await underlying.connect(auth: auth) }
    func disconnect() async { await underlying.disconnect() }
    func capabilities() async throws -> Set<IMAPCapability> { try await underlying.capabilities() }
    func listMailboxes() async throws -> [MailboxInfo] { try await underlying.listMailboxes() }
    func select(_ mailboxPath: String) async throws -> MailboxStatus { try await underlying.select(mailboxPath) }
    func status(_ mailboxPath: String) async throws -> MailboxStatus { try await underlying.status(mailboxPath) }
    func createMailbox(path: String) async throws { try await underlying.createMailbox(path: path) }
    func fetchEnvelopes(mailboxPath: String, uids: UIDRange, batchSize: Int) async throws -> [FetchedEnvelope] {
        try await underlying.fetchEnvelopes(mailboxPath: mailboxPath, uids: uids, batchSize: batchSize)
    }
    func fetchRecentEnvelopes(mailboxPath: String, count: Int, batchSize: Int) async throws -> [FetchedEnvelope] {
        try await underlying.fetchRecentEnvelopes(mailboxPath: mailboxPath, count: count, batchSize: batchSize)
    }
    func fetchEnvelopes(mailboxPath: String, changedSince modSeq: UInt64) async throws -> ChangedSinceResult {
        try await underlying.fetchEnvelopes(mailboxPath: mailboxPath, changedSince: modSeq)
    }
    func searchExistingUIDs(mailboxPath: String, uids: UIDRange) async throws -> Set<UInt32> {
        try await underlying.searchExistingUIDs(mailboxPath: mailboxPath, uids: uids)
    }
    func fetchFlags(mailboxPath: String, uids: UIDRange) async throws -> [UInt32: MessageFlags] {
        try await underlying.fetchFlags(mailboxPath: mailboxPath, uids: uids)
    }
    func fetchBody(mailboxPath: String, uid: UInt32) async throws -> MessageBodyContent {
        try await underlying.fetchBody(mailboxPath: mailboxPath, uid: uid)
    }
    func fetchMessageBody(mailboxPath: String, uid: UInt32, partId: String?) async throws -> Data {
        try await underlying.fetchMessageBody(mailboxPath: mailboxPath, uid: uid, partId: partId)
    }
    func store(mailboxPath: String, change: FlagChange) async throws {
        try await underlying.store(mailboxPath: mailboxPath, change: change)
        onStoreSucceeded()
    }
    func append(mailboxPath: String, messageData: Data, flags: MessageFlags) async throws -> UInt32? {
        try await underlying.append(mailboxPath: mailboxPath, messageData: messageData, flags: flags)
    }
    func move(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {
        try await underlying.move(mailboxPath: mailboxPath, uids: uids, to: destinationPath)
    }
    func copy(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {
        try await underlying.copy(mailboxPath: mailboxPath, uids: uids, to: destinationPath)
    }
    func expunge(mailboxPath: String) async throws { try await underlying.expunge(mailboxPath: mailboxPath) }
    nonisolated func idle(mailboxPath: String) -> AsyncThrowingStream<IdleEvent, Error> {
        underlying.idle(mailboxPath: mailboxPath)
    }
}
