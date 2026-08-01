import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

@Suite("AccountSyncer initial sync — Task #69 automatic retry")
struct AccountSyncerRetryTests {
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

    // MARK: - Task #69: 同期エラーの自動リトライ (5回) と表示抑制

    /// Builds a fresh `FakeIMAPSession` per `sessionFactory` call — mirrors
    /// what `AccountSyncer.connectWithRetry` actually does on each retry
    /// attempt (a new session, not a re-`connect()` of the same instance) —
    /// scripted to fail `connect()` for the first `failCount` calls and
    /// succeed (with `succeedingScript`) from then on. Lets a test exercise
    /// "N connect failures then a success" within *one* `performInitialSync`/
    /// `performIncrementalSync` call, which a plain `FakeIMAPSession.Script
    /// .failConnection` (fixed for that session's whole lifetime) can't do
    /// on its own — `FlakyCallController` below is the mailbox-level
    /// counterpart, needed because *that* retry reuses one session instance
    /// instead of asking `sessionFactory` again.
    private final class ConnectFailureSchedule: @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        private let failCount: Int
        private let error: MailTransportError
        private let succeedingScript: FakeIMAPSession.Script

        init(failCount: Int, error: MailTransportError, succeedingScript: FakeIMAPSession.Script = FakeIMAPSession.Script()) {
            self.failCount = failCount
            self.error = error
            self.succeedingScript = succeedingScript
        }

        var calls: Int { lock.withLock { callCount } }

        func makeSession(config: IMAPConfig) -> any IMAPSessionProtocol {
            let thisCall: Int = lock.withLock {
                callCount += 1
                return callCount
            }
            if thisCall <= failCount {
                return FakeIMAPSession(config: config, script: FakeIMAPSession.Script(failConnection: error))
            }
            return FakeIMAPSession(config: config, script: succeedingScript)
        }
    }

    /// A `SyncRetryPolicy` whose `.other`-class backoff sleep is a no-op —
    /// every retry test below wants the retry *logic* (attempt counts,
    /// which class of error records what) without actually waiting through
    /// real 2s/4s/8s/16s delays.
    private static let instantRetryPolicy = SyncRetryPolicy(sleep: { _ in })

    @Test("Task #69: an account-level connect failure retries automatically — 4 failures then a 5th success never records lastSyncError")
    func connectRetrySucceedsBeforeExhaustingAttempts() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let succeedingScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0)]
        )
        let schedule = ConnectFailureSchedule(
            failCount: 4,
            error: .serverError(underlyingDescription: "temporary hiccup"),
            succeedingScript: succeedingScript
        )
        let syncer = AccountSyncer(account: account, database: database, retryPolicy: Self.instantRetryPolicy, sessionFactory: schedule.makeSession)

        _ = try await syncer.performIncrementalSync(auth: auth)

        #expect(schedule.calls == 5, "the 5th attempt (the one that finally connects) must have happened")
        let row = try #require(try await database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) })
        #expect(row.lastSyncError == nil)
        #expect(row.lastSyncErrorAt == nil)
    }

    @Test("Task #69: 5 consecutive account-level connect failures finally record lastSyncError, stopping at exactly 5 attempts")
    func connectRetryExhaustsAfterFiveAttempts() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let schedule = ConnectFailureSchedule(failCount: .max, error: .serverError(underlyingDescription: "server is down"))
        let syncer = AccountSyncer(account: account, database: database, retryPolicy: Self.instantRetryPolicy, sessionFactory: schedule.makeSession)

        await #expect(throws: (any Error).self) {
            try await syncer.performIncrementalSync(auth: auth)
        }

        #expect(schedule.calls == 5, "must stop after maxAttempts, not keep retrying forever")
        let row = try #require(try await database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) })
        #expect(row.lastSyncError != nil)
        #expect(row.lastSyncErrorAt != nil)
    }

    @Test("Task #69: an authentication failure never retries, even with autoRetry enabled")
    func authenticationFailureNeverRetries() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "wrong")

        let schedule = ConnectFailureSchedule(failCount: .max, error: .authenticationFailed(underlyingDescription: "bad password"))
        let syncer = AccountSyncer(account: account, database: database, retryPolicy: Self.instantRetryPolicy, sessionFactory: schedule.makeSession)

        await #expect(throws: (any Error).self) {
            try await syncer.performIncrementalSync(auth: auth)
        }

        #expect(schedule.calls == 1, "authenticationFailed must not retry at all")
        let row = try #require(try await database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) })
        #expect(row.lastSyncError != nil)
    }

    @Test("Task #69: a connectionFailed (offline-like) connect failure accumulates across separate sync calls instead of retrying in-process")
    func connectionFailedAccumulatesAcrossCallsWithoutInProcessRetry() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let schedule = ConnectFailureSchedule(failCount: .max, error: .connectionFailed(underlyingDescription: "could not reach host"))
        let syncer = AccountSyncer(account: account, database: database, retryPolicy: Self.instantRetryPolicy, sessionFactory: schedule.makeSession)

        for _ in 1...4 {
            await #expect(throws: (any Error).self) {
                try await syncer.performIncrementalSync(auth: auth)
            }
        }
        #expect(schedule.calls == 4, "no in-process retry: exactly one session per external call")
        let afterFour = try #require(try await database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) })
        #expect(afterFour.lastSyncError == nil, "must not show until the 5th cumulative failure")

        await #expect(throws: (any Error).self) {
            try await syncer.performIncrementalSync(auth: auth)
        }
        #expect(schedule.calls == 5)
        let afterFive = try #require(try await database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) })
        #expect(afterFive.lastSyncError != nil)
    }

    @Test("Task #69: autoRetry: false (manual pull-to-refresh) never retries, even for an otherwise-retryable error")
    func manualSyncNeverRetries() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let schedule = ConnectFailureSchedule(failCount: .max, error: .serverError(underlyingDescription: "temporary hiccup"))
        let syncer = AccountSyncer(account: account, database: database, retryPolicy: Self.instantRetryPolicy, sessionFactory: schedule.makeSession)

        await #expect(throws: (any Error).self) {
            try await syncer.performIncrementalSync(auth: auth, autoRetry: false)
        }

        #expect(schedule.calls == 1, "a manual call must never retry")
        let row = try #require(try await database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) })
        #expect(row.lastSyncError != nil, "a manual failure must still show up immediately")
    }

    @Test("Task #69: a second automatic sync call for the same account is skipped while the first is still retrying")
    func autoRetryDedupSkipsConcurrentCall() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let succeedingScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0)]
        )
        // Fails once (an `.other`-class error), so the first call is
        // guaranteed to still be running (mid backoff-sleep) when the
        // second, deduped call arrives.
        let schedule = ConnectFailureSchedule(
            failCount: 1,
            error: .serverError(underlyingDescription: "temporary hiccup"),
            succeedingScript: succeedingScript
        )
        // Gated rather than instant: the sleep only returns once this test
        // explicitly opens the gate, so the first call is provably still
        // in flight while the second call is issued below.
        let gate = SleepGate()
        let syncer = AccountSyncer(
            account: account,
            database: database,
            retryPolicy: SyncRetryPolicy(sleep: { _ in await gate.wait() }),
            sessionFactory: schedule.makeSession
        )

        let firstTask = Task { try await syncer.performIncrementalSync(auth: auth) }
        while await !syncer.isAutoRetryingForTesting() {
            await Task.yield()
        }

        let secondProgress = try await syncer.performIncrementalSync(auth: auth)
        #expect(secondProgress == MailboxSyncer.Progress(), "a concurrent automatic call must be a no-op while the first is retrying")
        #expect(schedule.calls == 1, "the deduped call must not have opened its own connection")

        await gate.open()
        _ = try await firstTask.value
        #expect(schedule.calls == 2, "the first call's retry should have gone on to succeed once the gate opened")
    }

    /// A `CheckedContinuation`-backed gate a retry test can use as a
    /// controllable backoff "sleep" — lets the test provably keep a call
    /// stuck mid-retry until it explicitly wants that call to proceed,
    /// rather than racing real timers.
    private actor SleepGate {
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("Task #69: a mailbox-level failure retries automatically too — 4 failures then a 5th success never records that mailbox's lastSyncError")
    func mailboxRetrySucceedsBeforeExhaustingAttempts() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let flaky = FakeIMAPSession.FlakyCallController(failCount: 4, error: .serverError(underlyingDescription: "temporary hiccup"))
        let script = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": [makeInbox(uid: 1, subject: "ようこそ otegami へ")]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)],
            flakyFetchRecentEnvelopes: flaky
        )
        let syncer = AccountSyncer(
            account: account,
            database: database,
            retryPolicy: Self.instantRetryPolicy,
            sessionFactory: { config in FakeIMAPSession(config: config, script: script) }
        )

        let progress = try await syncer.performInitialSync(auth: auth)
        #expect(progress.envelopesFetched == 1, "the 5th attempt should have succeeded and fetched the envelope")

        let inboxRecord = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "INBOX").fetchOne(db)
            }
        )
        #expect(inboxRecord.lastSyncError == nil)
        #expect(inboxRecord.lastSyncErrorAt == nil)
    }

    @Test("Task #69: 5 consecutive mailbox-level failures finally record that mailbox's lastSyncError, without aborting the whole initial sync")
    func mailboxRetryExhaustsAfterFiveAttempts() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let flaky = FakeIMAPSession.FlakyCallController(failCount: .max, error: .serverError(underlyingDescription: "server is down"))
        let script = FakeIMAPSession.Script(
            mailboxes: [inbox],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)],
            flakyFetchRecentEnvelopes: flaky
        )
        let syncer = AccountSyncer(
            account: account,
            database: database,
            retryPolicy: Self.instantRetryPolicy,
            sessionFactory: { config in FakeIMAPSession(config: config, script: script) }
        )

        // Must not throw: a mailbox-level failure never propagates out of
        // `performInitialSync` — only a `connect()`-level failure does.
        let progress = try await syncer.performInitialSync(auth: auth)
        #expect(progress.envelopesFetched == 0)

        let inboxRecord = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "INBOX").fetchOne(db)
            }
        )
        #expect(inboxRecord.lastSyncError != nil)
        #expect(inboxRecord.lastSyncErrorAt != nil)
    }

    @Test("Task #69: autoRetry: false applies to mailbox-level failures too — one attempt, recorded immediately even though a retry would have succeeded")
    func manualMailboxSyncNeverRetries() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        // Only fails once — if this retried at all, the 2nd attempt would
        // succeed and no failure would ever be recorded.
        let flaky = FakeIMAPSession.FlakyCallController(failCount: 1, error: .serverError(underlyingDescription: "temporary hiccup"))
        let script = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": [makeInbox(uid: 1, subject: "ようこそ otegami へ")]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)],
            flakyFetchRecentEnvelopes: flaky
        )
        let syncer = AccountSyncer(
            account: account,
            database: database,
            retryPolicy: Self.instantRetryPolicy,
            sessionFactory: { config in FakeIMAPSession(config: config, script: script) }
        )

        _ = try await syncer.performInitialSync(auth: auth, autoRetry: false)

        let inboxRecord = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "INBOX").fetchOne(db)
            }
        )
        #expect(inboxRecord.lastSyncError != nil, "a manual/non-retrying sync must record the single attempt's failure immediately")
    }

}
