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

        // Recent (well inside the 3-day `unifiedInboxPrefetchWindow`), not a
        // fixed 2023 timestamp — this call defaults `now:` to the real
        // `Date()`, so a fixed-past date would fall outside the window and
        // never even reach the fetch step (see the dedicated
        // "excludes messages older than the window" test below for that
        // behavior).
        let base = Date().addingTimeInterval(-3600)
        _ = try await insertInboxMessage(database: database, accountId: account.id, uid: 1, subject: "old", internalDate: base)
        let alreadyFetchedId = try await insertInboxMessage(
            database: database, accountId: account.id, uid: 2, subject: "already", internalDate: base.addingTimeInterval(1800), bodyState: .fetched
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

        let base = Date().addingTimeInterval(-3600)
        _ = try await insertInboxMessage(database: database, accountId: account1.id, uid: 1, subject: "a1", internalDate: base)
        _ = try await insertInboxMessage(database: database, accountId: account2.id, uid: 1, subject: "a2", internalDate: base.addingTimeInterval(1800))

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

    // MARK: - Task #63: recency window (replaces the old flat 30-message limit)

    @Test("excludes notFetched messages received before the 3-day unifiedInboxPrefetchWindow, even though a flat count would have included them")
    func excludesMessagesOlderThanTheWindow() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "account-1", email: "a1@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let windowStart = now.addingTimeInterval(-SyncCoordinator.unifiedInboxPrefetchWindow)
        _ = try await insertInboxMessage(
            database: database, accountId: account.id, uid: 1, subject: "recent", internalDate: windowStart.addingTimeInterval(3600)
        )
        _ = try await insertInboxMessage(
            database: database, accountId: account.id, uid: 2, subject: "stale", internalDate: windowStart.addingTimeInterval(-3600)
        )

        // Only uid 1 ("recent") has a scripted body — if the window
        // exclusion failed and uid 2 ("stale") were attempted too, its
        // `fetchBody` would hit the fake's "no scripted body" failure path
        // and be silently skipped rather than crash, so the count/state
        // assertions below (not just "didn't throw") are what actually
        // proves the exclusion happened at the query level.
        let script = FakeIMAPSession.Script(statusByPath: inboxStatus, bodiesByPath: ["INBOX": [1: MessageBodyContent(plainText: "本文")]])
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        let fetchedCount = await coordinator.prefetchUnifiedInboxBodiesIfNeeded(accounts: [account], now: now) { _ in self.auth }
        #expect(fetchedCount == 1)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.first { $0.subject == "recent" }?.bodyState == .fetched)
        #expect(messages.first { $0.subject == "stale" }?.bodyState == .notFetched)
    }

    @Test("caps the number of messages fetched at unifiedInboxPrefetchCandidateLimit even when more notFetched messages exist inside the window")
    func capsAtCandidateLimitSafetyCeiling() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "account-1", email: "a1@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let overLimitCount = SyncCoordinator.unifiedInboxPrefetchCandidateLimit + 5
        // Built up front (not mutated inside the `@Sendable` `dbWriter.write`
        // closure below, which Swift 6 strict concurrency disallows for a
        // captured `var`) — a pure function of `overLimitCount`, so
        // precomputing it here changes nothing about what gets scripted.
        let bodiesByUID = Dictionary(
            uniqueKeysWithValues: (0..<overLimitCount).map { i in (UInt32(i + 1), MessageBodyContent(plainText: "本文\(i)")) }
        )
        try await database.dbWriter.write { db in
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            for i in 0..<overLimitCount {
                // Distinct, strictly-increasing-with-i dates a few seconds
                // apart — all comfortably inside the 3-day window, but
                // deterministically ordered so "which `unifiedInboxPrefetchCandidateLimit`
                // survive the cap" isn't ambiguous.
                var message = MessageRecord(
                    mailboxId: mailbox.id!,
                    uid: Int64(i + 1),
                    subject: "msg-\(i)",
                    internalDate: now.addingTimeInterval(Double(i))
                )
                try message.insert(db)
            }
        }

        let script = FakeIMAPSession.Script(statusByPath: inboxStatus, bodiesByPath: ["INBOX": bodiesByUID])
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        let fetchedCount = await coordinator.prefetchUnifiedInboxBodiesIfNeeded(accounts: [account], now: now) { _ in self.auth }
        #expect(fetchedCount == SyncCoordinator.unifiedInboxPrefetchCandidateLimit)
    }

    // MARK: - Task #63: post-sync trigger ("各メールボックスの同期完了後にも1回")

    /// Push 通知起点バックグラウンド受信 Phase 1: `schedulesPostSyncPrefetch`
    /// defaults to `true`, so every existing caller of `syncAccountIncrementally`
    /// that doesn't pass it (every test/call site above and below this one)
    /// keeps triggering the post-sync prefetch exactly as before — this test
    /// exercises the opposite, explicit `false` case directly at the
    /// `SyncCoordinator` level (`PushTriggeredInboxSyncTests` covers the
    /// same suppression through its one real caller, `PushTriggeredInboxSync`).
    @Test("schedulesPostSyncPrefetch: false suppresses the post-sync prefetch trigger entirely")
    func schedulesPostSyncPrefetchFalseSuppressesTrigger() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "account-1", email: "a1@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }

        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let script = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 1)],
            bodiesByPath: ["INBOX": [1: MessageBodyContent(plainText: "本文")]]
        )
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        _ = try await coordinator.syncAccount(account, auth: auth)
        let mailboxId = try await database.dbWriter.read { db in
            try MailboxRecord
                .filter(Column("accountId") == account.id)
                .filter(Column("path") == "INBOX")
                .fetchOne(db)!
                .id!
        }
        // A notFetched message that would otherwise be a valid prefetch
        // candidate — same setup as `postSyncTriggerPrefetchesAfterIncrementalSync`
        // just above, so if `schedulesPostSyncPrefetch: false` failed to
        // suppress the trigger, `waitForPendingPostSyncPrefetchForTesting()`
        // below would return `1` instead of `nil`.
        try await database.dbWriter.write { db in
            var message = MessageRecord(mailboxId: mailboxId, uid: 1, subject: "new mail", internalDate: Date())
            try message.insert(db)
        }

        _ = try await coordinator.syncAccountIncrementally(account, auth: auth, schedulesPostSyncPrefetch: false)

        let prefetchResult = await coordinator.waitForPendingPostSyncPrefetchForTesting()
        #expect(prefetchResult == nil)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.first { $0.subject == "new mail" }?.bodyState == .notFetched, "no prefetch ran, so the body must still be unfetched")
    }

    @Test("a successful syncAccountIncrementally triggers a background prefetch of the newly-synced account's notFetched bodies")
    func postSyncTriggerPrefetchesAfterIncrementalSync() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "account-1", email: "a1@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }

        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        // `messageCount: 1` (matching the one message this test inserts
        // directly below) — not `0`: `MailboxSyncer.refetchAndDiffFlags`'s
        // non-CONDSTORE flag-sync step treats "server says N>0 messages
        // exist but my scripted UID-range refetch came back empty" as "the
        // refetch itself came up short, don't trust it", but "server says
        // 0 messages exist" as authoritative proof every locally-stored UID
        // was expunged — with `messageCount: 0` here it would delete the
        // very message this test just inserted before the post-sync
        // prefetch trigger ever got to see it.
        let script = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 1)],
            bodiesByPath: ["INBOX": [1: MessageBodyContent(plainText: "本文")]]
        )
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        // Establishes the mailbox's uidValidity baseline the same way
        // `SyncCoordinatorTests` does, so the incremental sync below takes
        // the normal differential path rather than a full
        // uidValidity-changed resync.
        _ = try await coordinator.syncAccount(account, auth: auth)

        let mailboxId = try await database.dbWriter.read { db in
            try MailboxRecord
                .filter(Column("accountId") == account.id)
                .filter(Column("path") == "INBOX")
                .fetchOne(db)!
                .id!
        }
        // Simulates new mail an incremental sync's own envelope fetch would
        // discover — inserted directly rather than scripted through
        // `FakeIMAPSession`'s `changedSinceEnvelopesByPath`, since only the
        // post-sync *prefetch* trigger under test cares that this row
        // exists and is `notFetched` by the time `syncAccountIncrementally`
        // returns, not how it got there.
        try await database.dbWriter.write { db in
            var message = MessageRecord(mailboxId: mailboxId, uid: 1, subject: "new mail", internalDate: Date())
            try message.insert(db)
        }

        _ = try await coordinator.syncAccountIncrementally(account, auth: auth)

        // Synchronizes with the detached, low-priority `Task` the trigger
        // fires (`schedulePostSyncPrefetchIfNeeded`'s doc comment) — see
        // `waitForPendingPostSyncPrefetchForTesting()`'s doc comment for why
        // this test-only hook exists instead of racing it with a sleep.
        let fetchedCount = await coordinator.waitForPendingPostSyncPrefetchForTesting()
        #expect(fetchedCount == 1)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.first { $0.subject == "new mail" }?.bodyState == .fetched)
    }

    @Test("the post-sync prefetch trigger is debounced per account: a second sync moments later doesn't re-run it")
    func postSyncTriggerDebouncesPerAccount() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "account-1", email: "a1@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }

        let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        // `messageCount: 1` (matching the one message this test inserts
        // directly below) — not `0`: `MailboxSyncer.refetchAndDiffFlags`'s
        // non-CONDSTORE flag-sync step treats "server says N>0 messages
        // exist but my scripted UID-range refetch came back empty" as "the
        // refetch itself came up short, don't trust it", but "server says
        // 0 messages exist" as authoritative proof every locally-stored UID
        // was expunged — with `messageCount: 0` here it would delete the
        // very message this test just inserted before the post-sync
        // prefetch trigger ever got to see it.
        let script = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 1)],
            bodiesByPath: ["INBOX": [1: MessageBodyContent(plainText: "本文")]]
        )
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        _ = try await coordinator.syncAccount(account, auth: auth)
        let mailboxId = try await database.dbWriter.read { db in
            try MailboxRecord
                .filter(Column("accountId") == account.id)
                .filter(Column("path") == "INBOX")
                .fetchOne(db)!
                .id!
        }
        try await database.dbWriter.write { db in
            var message = MessageRecord(mailboxId: mailboxId, uid: 1, subject: "new mail", internalDate: Date())
            try message.insert(db)
        }

        _ = try await coordinator.syncAccountIncrementally(account, auth: auth)
        let first = await coordinator.waitForPendingPostSyncPrefetchForTesting()
        #expect(first == 1)

        // A second sync immediately after (well within
        // `postSyncPrefetchInterval`'s 60s) must not reschedule the
        // trigger. If it wrongly did, the message is already `.fetched` by
        // now — the query candidate list would be empty and the re-run
        // would report `0`, distinguishable from the debounced case simply
        // returning the *same already-completed* `1` from the first task.
        _ = try await coordinator.syncAccountIncrementally(account, auth: auth)
        let second = await coordinator.waitForPendingPostSyncPrefetchForTesting()
        #expect(second == first)
    }
}
