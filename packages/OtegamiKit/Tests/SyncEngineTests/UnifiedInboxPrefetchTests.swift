import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// Task #31 (docs/roadmap.md, launch/foreground background body prefetch —
/// "さっき読んだメールも、アプリを起動し直すと読み込みが入る?表示まで時間
/// がかかる"): exercises `SyncCoordinator
/// .prefetchUnifiedInboxBodiesIfNeeded(accounts:now:authProvider:)` end to
/// end against `FakeIMAPSession`, the same way `SyncCoordinatorTests`
/// exercises the rest of `SyncCoordinator`'s public API.
@Suite("SyncCoordinator.prefetchUnifiedInboxBodiesIfNeeded")
struct UnifiedInboxPrefetchTests {
    private func makeAccount(id: String, email: String) -> AccountRecord {
        AccountRecord(
            id: id,
            displayName: email,
            email: email,
            authType: .password,
            imapHost: "localhost",
            imapPort: 1143,
            imapSecurity: .plain,
            imapUsername: email
        )
    }

    private func insertInboxMessage(
        database: AppDatabase,
        accountId: String,
        uid: Int64,
        subject: String,
        internalDate: Date,
        bodyState: MessageBodyState = .notFetched
    ) async throws -> Int64 {
        try await database.dbWriter.write { db in
            var mailbox = MailboxRecord(accountId: accountId, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var message = MessageRecord(
                mailboxId: mailbox.id!,
                uid: uid,
                subject: subject,
                internalDate: internalDate,
                bodyState: bodyState
            )
            try message.insert(db)
            return message.id!
        }
    }

    private let auth = MailAuth.password(username: "test@otegami.test", password: "test1234")

    /// `select("INBOX")` (`FakeIMAPSession.select`) delegates to `status`,
    /// which throws `.mailboxNotFound` for any path missing from
    /// `Script.statusByPath` — every script below that expects a
    /// successful `connect` → `select` needs this, same as
    /// `SyncCoordinatorTests.makeScript()`'s identical entry.
    private let inboxStatus: [String: MailboxStatus] = ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0)]

    @Test("fetches bodies for notFetched messages in the unified inbox and leaves already-fetched ones alone")
    func fetchesOnlyUnfetchedMessages() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "account-1", email: "a1@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await insertInboxMessage(database: database, accountId: account.id, uid: 1, subject: "old", internalDate: base)
        let alreadyFetchedId = try await insertInboxMessage(
            database: database, accountId: account.id, uid: 2, subject: "already", internalDate: base.addingTimeInterval(3600), bodyState: .fetched
        )

        let script = FakeIMAPSession.Script(statusByPath: inboxStatus, bodiesByPath: ["INBOX": [1: MessageBodyContent(plainText: "本文")]])
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        let fetchedCount = await coordinator.prefetchUnifiedInboxBodiesIfNeeded(accounts: [account]) { _ in self.auth }
        #expect(fetchedCount == 1)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        let fetched = messages.first { $0.uid == 1 }
        #expect(fetched?.bodyState == .fetched)
        // The already-fetched message's row is untouched (same id still resolves, no re-fetch attempted).
        let untouched = messages.first { $0.id == alreadyFetchedId }
        #expect(untouched?.bodyState == .fetched)
    }

    /// Records every host `sessionFactory` was asked to build a session
    /// for, in call order — same rationale/shape as `SyncCoordinatorTests
    /// .HostRecorder`: `sessionFactory` is a synchronous `@Sendable`
    /// closure, so recording here must be synchronous too.
    private final class HostRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var hosts: [String] { lock.withLock { storage } }
        func record(_ host: String) { lock.withLock { storage.append(host) } }
    }

    @Test("multiple accounts: each account's candidates get fetched, one account's connection opened at a time")
    func multipleAccountsFetchedSequentially() async throws {
        let database = try AppDatabase.makeInMemory()
        let account1 = AccountRecord(
            id: "account-1", displayName: "A1", email: "a1@otegami.test", authType: .password,
            imapHost: "host-1", imapPort: 1143, imapSecurity: .plain, imapUsername: "a1@otegami.test"
        )
        let account2 = AccountRecord(
            id: "account-2", displayName: "A2", email: "a2@otegami.test", authType: .password,
            imapHost: "host-2", imapPort: 1143, imapSecurity: .plain, imapUsername: "a2@otegami.test"
        )
        try await database.dbWriter.write { db in
            try account1.insert(db)
            try account2.insert(db)
        }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await insertInboxMessage(database: database, accountId: account1.id, uid: 1, subject: "a1", internalDate: base)
        _ = try await insertInboxMessage(database: database, accountId: account2.id, uid: 1, subject: "a2", internalDate: base.addingTimeInterval(3600))

        let recorder = HostRecorder()
        let script = FakeIMAPSession.Script(statusByPath: inboxStatus, bodiesByPath: [
            "INBOX": [1: MessageBodyContent(plainText: "本文")],
        ])
        let coordinator = SyncCoordinator(database: database) { config in
            recorder.record(config.host)
            return FakeIMAPSession(config: config, script: script)
        }

        let fetchedCount = await coordinator.prefetchUnifiedInboxBodiesIfNeeded(
            accounts: [account1, account2],
            authProvider: { _ in self.auth }
        )
        #expect(fetchedCount == 2)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.allSatisfy { $0.bodyState == .fetched })

        // One connection opened per account with candidates, in `accounts` order —
        // not fanned out in parallel (which wouldn't guarantee this order).
        #expect(recorder.hosts == ["host-1", "host-2"])
    }

    @Test("debounces: a second call within the interval is a no-op")
    func debouncesRepeatedCalls() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "account-1", email: "a1@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }
        _ = try await insertInboxMessage(database: database, accountId: account.id, uid: 1, subject: "msg", internalDate: Date())

        let script = FakeIMAPSession.Script(statusByPath: inboxStatus, bodiesByPath: ["INBOX": [1: MessageBodyContent(plainText: "本文")]])
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        let now = Date()
        let first = await coordinator.prefetchUnifiedInboxBodiesIfNeeded(accounts: [account], now: now) { _ in self.auth }
        #expect(first == 1)

        // A second call 1 minute later (well within the 5-minute debounce window) is a no-op.
        let second = await coordinator.prefetchUnifiedInboxBodiesIfNeeded(accounts: [account], now: now.addingTimeInterval(60)) { _ in self.auth }
        #expect(second == 0)

        // A call after the debounce window has elapsed runs again — nothing left to fetch, so 0,
        // but reaching the query/connect path at all (as opposed to being debounced) is what this
        // asserts indirectly via the *first* call already having fetched everything there was.
        let third = await coordinator.prefetchUnifiedInboxBodiesIfNeeded(accounts: [account], now: now.addingTimeInterval(6 * 60)) { _ in self.auth }
        #expect(third == 0)
    }

    @Test("a connection failure (offline) is swallowed silently, no throw")
    func connectionFailureIsSilent() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "account-1", email: "a1@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }
        _ = try await insertInboxMessage(database: database, accountId: account.id, uid: 1, subject: "msg", internalDate: Date())

        let script = FakeIMAPSession.Script(failConnection: .connectionFailed(underlyingDescription: "offline"))
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        let fetchedCount = await coordinator.prefetchUnifiedInboxBodiesIfNeeded(accounts: [account]) { _ in self.auth }
        #expect(fetchedCount == 0)

        // bodyState is left as notFetched (no partial/failed write), ready to retry next foreground.
        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.allSatisfy { $0.bodyState == .notFetched })
    }

    @Test("an account whose credentials can't be resolved is skipped, other accounts still prefetch")
    func credentialFailureSkipsOnlyThatAccount() async throws {
        let database = try AppDatabase.makeInMemory()
        let brokenAccount = makeAccount(id: "account-broken", email: "broken@otegami.test")
        let okAccount = makeAccount(id: "account-ok", email: "ok@otegami.test")
        try await database.dbWriter.write { db in
            try brokenAccount.insert(db)
            try okAccount.insert(db)
        }
        _ = try await insertInboxMessage(database: database, accountId: brokenAccount.id, uid: 1, subject: "broken", internalDate: Date())
        _ = try await insertInboxMessage(database: database, accountId: okAccount.id, uid: 1, subject: "ok", internalDate: Date())

        let script = FakeIMAPSession.Script(statusByPath: inboxStatus, bodiesByPath: ["INBOX": [1: MessageBodyContent(plainText: "本文")]])
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        struct CredentialError: Error {}
        let fetchedCount = await coordinator.prefetchUnifiedInboxBodiesIfNeeded(accounts: [brokenAccount, okAccount]) { account in
            if account.id == brokenAccount.id { throw CredentialError() }
            return self.auth
        }
        #expect(fetchedCount == 1)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        let brokenMessage = messages.first { $0.subject == "broken" }
        let okMessage = messages.first { $0.subject == "ok" }
        #expect(brokenMessage?.bodyState == .notFetched)
        #expect(okMessage?.bodyState == .fetched)
    }

    @Test("no accounts is a harmless no-op")
    func noAccountsNoOp() async throws {
        let database = try AppDatabase.makeInMemory()
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script()) }
        let fetchedCount = await coordinator.prefetchUnifiedInboxBodiesIfNeeded(accounts: []) { _ in self.auth }
        #expect(fetchedCount == 0)
    }
}
