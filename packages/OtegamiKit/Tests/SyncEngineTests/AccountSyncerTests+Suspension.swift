import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

@Suite("AccountSyncer initial sync — Task #192 database suspension")
struct AccountSyncerSuspensionTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test",
            email: "test1@otegami.test",
            authType: .password,
            imapHost: "localhost",
            imapPort: 1143,
            imapSecurity: .plain,
            imapUsername: "test1@otegami.test"
        )
    }

    private func makeInbox(uid: UInt32, subject: String, references: [String] = []) -> FetchedEnvelope {
        FetchedEnvelope(
            uid: uid,
            messageId: "<seed-\(uid)@otegami.test>",
            inReplyTo: references.last,
            references: references,
            subject: subject,
            from: [EmailAddress(name: "Aiko", address: "aiko@otegami.test")],
            to: [EmailAddress(address: "test1@otegami.test")],
            cc: [],
            bcc: [],
            replyTo: [],
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            internalDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            flags: [],
            size: 512
        )
    }

    /// A `SyncRetryPolicy` whose `.other`-class backoff sleep is a no-op —
    /// every retry test below wants the retry *logic* (attempt counts,
    /// which class of error records what) without actually waiting through
    /// real 2s/4s/8s/16s delays.
    private static let instantRetryPolicy = SyncRetryPolicy(sleep: { _ in })

    // MARK: Task #192 — database suspension (0xDEAD10CC)

    /// A suspended database (0xDEAD10CC-prevention — see
    /// `DatabaseSuspensionSupport`'s doc comment) failing the
    /// per-mailbox envelope-upsert write must classify as `.suspended`,
    /// not `.other`: no in-process retry (`fetchRecentEnvelopes` must be
    /// called exactly once), and no persisted `MailboxRecord
    /// .lastSyncError` — a suspension isn't a real sync failure worth
    /// showing anyone. This suspends the *real* database (GRDB's own
    /// `Database.suspendNotification`) right after the scripted
    /// `fetchRecentEnvelopes` call returns, landing the failure exactly on
    /// `performInitialSync`'s envelope-upsert `database.dbWriter.write`
    /// right after it — the same real-world timing window
    /// `OpQueueProcessorTests.suspendedDatabaseAbortsReplayWithoutRecordingFailure`
    /// exercises for the sibling `OpQueueProcessor` path.
    ///
    /// `performInitialSync`'s own unconditional final `ThreadAssigner
    /// .assignAllUnthreaded` write (after the per-mailbox loop) also lands
    /// on the still-suspended database — this test never posts
    /// `resumeNotification` mid-run, deliberately, since a real background
    /// suspend has no such "resume partway through" moment either — so the
    /// overall call is expected to throw too. What this test actually
    /// verifies is that the per-mailbox failure specifically took the
    /// "give up silently" path rather than the "retry 5 times, then
    /// persist a confusing error" path.
    @Test("a suspended database aborts a mailbox's sync without retrying or recording lastSyncError")
    func suspendedDatabaseDuringMailboxSyncIsNotRecordedAsFailure() async throws {
        // `Database.suspendNotification` is process-global (see
        // `DatabaseSuspensionTestLock`'s doc comment) — serialize against
        // every other test in this run that also posts it for real.
        try await DatabaseSuspensionTestLock.withLock {
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            configuration.observesSuspensionNotifications = true
            // File-backed — GRDB 7.11.1's in-memory `DatabaseQueue` init never
            // registers the suspend/resume `NotificationCenter` observers at
            // all (see `DatabaseSuspensionTests.makeSuspendableQueue()`'s doc
            // comment in OtegamiStoreTests for the confirmed source-level
            // reason), so an in-memory queue here would make this test inert.
            let dbPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("otegami-accountsyncer-suspension-test-\(UUID().uuidString).sqlite").path
            let database = try AppDatabase(DatabaseQueue(path: dbPath, configuration: configuration))
            defer {
                NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
                try? FileManager.default.removeItem(atPath: dbPath)
            }
            let account = makeAccount()
            try await database.dbWriter.write { db in try account.insert(db) }
            let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

            let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
            let script = FakeIMAPSession.Script(
                mailboxes: [inbox],
                envelopesByPath: ["INBOX": [makeInbox(uid: 1, subject: "test")]],
                statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)]
            )
            let fetchCount = LockedBox(0)
            let syncer = AccountSyncer(
                account: account, database: database, retryPolicy: Self.instantRetryPolicy
            ) { config in
                SuspendingEnvelopeFetchSession(config: config, script: script) {
                    fetchCount.increment()
                    NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
                }
            }

            do {
                _ = try await syncer.performInitialSync(auth: auth)
                Issue.record("expected performInitialSync's own final ThreadAssigner write to also observe the still-suspended database and throw")
            } catch {
                #expect(DatabaseSuspensionSupport.isSuspensionError(error))
            }

            #expect(fetchCount.value == 1, "a .suspended classification must not retry fetchRecentEnvelopes")

            NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
            let mailbox = try #require(try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id).fetchOne(db)
            })
            #expect(mailbox.lastSyncError == nil, "a suspension isn't a real sync failure — must never surface as a mailbox error banner")
            #expect(mailbox.lastSyncErrorAt == nil)
        }
    }
}

/// Minimal `Sendable` mutable counter for the closure-captured assertion in
/// `idleLoopDoesNotImmediatelyRetryAfterAuthFailure` above (a plain `var`
/// can't be mutated from the non-isolated `sessionFactory` closure).
private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int
    init(_ value: Int) { _value = value }
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

/// Task #192: a minimal `IMAPSessionProtocol` double, mirroring
/// `OpQueueProcessorTests.SuspendingStoreSession`'s shape — everything
/// delegates to a real `FakeIMAPSession` except `fetchRecentEnvelopes`,
/// which returns the scripted envelopes normally and then runs
/// `onFetched` (`suspendedDatabaseDuringMailboxSyncIsNotRecordedAsFailure`
/// posts `Database.suspendNotification` there). This lands the suspension
/// right between `AccountSyncer.performInitialSync`'s
/// `fetchRecentEnvelopes` call and the `database.dbWriter.write` that
/// upserts what it returned — the envelope-upsert write is then the one
/// that actually observes the suspended database.
private actor SuspendingEnvelopeFetchSession: IMAPSessionProtocol {
    private let underlying: FakeIMAPSession
    private let onFetched: @Sendable () -> Void

    init(config: IMAPConfig) {
        self.underlying = FakeIMAPSession(config: config)
        self.onFetched = {}
    }

    init(config: IMAPConfig, script: FakeIMAPSession.Script, onFetched: @escaping @Sendable () -> Void) {
        self.underlying = FakeIMAPSession(config: config, script: script)
        self.onFetched = onFetched
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
    func fetchEnvelopes(mailboxPath: String, uids: UIDSet) async throws -> [FetchedEnvelope] {
        try await underlying.fetchEnvelopes(mailboxPath: mailboxPath, uids: uids)
    }
    func fetchRecentEnvelopes(mailboxPath: String, count: Int, batchSize: Int, status: MailboxStatus) async throws -> [FetchedEnvelope] {
        let result = try await underlying.fetchRecentEnvelopes(mailboxPath: mailboxPath, count: count, batchSize: batchSize, status: status)
        onFetched()
        return result
    }
    func fetchEnvelopes(mailboxPath: String, changedSince modSeq: UInt64) async throws -> ChangedSinceResult {
        try await underlying.fetchEnvelopes(mailboxPath: mailboxPath, changedSince: modSeq)
    }
    func fetchFlags(mailboxPath: String, changedSince modSeq: UInt64) async throws -> ChangedSinceFlagsResult {
        try await underlying.fetchFlags(mailboxPath: mailboxPath, changedSince: modSeq)
    }
    func searchExistingUIDs(mailboxPath: String, uids: UIDRange) async throws -> Set<UInt32> {
        try await underlying.searchExistingUIDs(mailboxPath: mailboxPath, uids: uids)
    }
    func searchMessages(mailboxPath: String, query: String) async throws -> Set<UInt32> {
        try await underlying.searchMessages(mailboxPath: mailboxPath, query: query)
    }
    func fetchFlags(mailboxPath: String, uids: UIDRange) async throws -> [UInt32: MessageFlags] {
        try await underlying.fetchFlags(mailboxPath: mailboxPath, uids: uids)
    }
    func fetchFlags(mailboxPath: String, uids: UIDSet) async throws -> [UInt32: MessageFlags] {
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
