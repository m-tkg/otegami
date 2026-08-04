import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

/// Coverage for `PushTriggeredInboxSync.run(...)` — push 通知起点バックグ
/// ラウンド受信 Phase 1's OtegamiKit-side entry point, the `NotificationService`
/// Extension calls this on every push receipt to actually pull the new
/// message's envelope (and, optionally, body) into the shared database.
/// Exercised the same way `PushNotificationActionExecutorTests` exercises
/// its sibling (`FakeIMAPSession` + `AppDatabase.makeInMemory()`, no real
/// IMAP server or Keychain).
@Suite("PushTriggeredInboxSync")
struct PushTriggeredInboxSyncTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
    }

    /// Inserts an account plus an INBOX mailbox directly, mirroring
    /// `PushNotificationActionExecutorTests`' identical helper — establishes
    /// the mailbox's `uidValidity` baseline so `.inboxOnly` incremental sync
    /// below takes the normal differential path.
    private func makeAccountWithInbox(database: AppDatabase) async throws -> (account: AccountRecord, inbox: MailboxRecord) {
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let inbox = try await database.dbWriter.write { db -> MailboxRecord in
            var record = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1)
            try record.insert(db)
            return record
        }
        return (account, inbox)
    }

    private func makeEnvelope(uid: UInt32, subject: String = "新着") -> FetchedEnvelope {
        FetchedEnvelope(
            uid: uid,
            messageId: "<push-\(uid)@otegami.test>",
            inReplyTo: nil,
            references: [],
            subject: subject,
            from: [EmailAddress(name: "Aiko", address: "aiko@otegami.test")],
            to: [EmailAddress(address: "test1@otegami.test")],
            cc: [], bcc: [], replyTo: [],
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            internalDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            flags: [], size: 512
        )
    }

    private let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

    private let inboxInfo = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])

    // MARK: (a) new UID gets synced and Outcome.message is returned

    @Test("run syncs a not-yet-known UID's envelope and returns it, along with the unread count")
    func syncsUnsyncedUIDAndReturnsMessage() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _) = try await makeAccountWithInbox(database: database)

        let script = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 42)]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 43, highestModSeq: 0, messageCount: 1)]
        )

        let outcome = await PushTriggeredInboxSync.run(
            accountId: account.id, uidNext: 43, fetchBodyPreview: false,
            database: database, auth: auth,
            sessionFactory: { config in FakeIMAPSession(config: config, script: script) }
        )

        #expect(outcome.message?.uid == 42)
        #expect(outcome.unreadCount == 1)

        let stored = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(stored.count == 1)
        #expect(stored.first?.uid == 42)
    }

    // MARK: (b) two consecutive runs are idempotent

    @Test("two consecutive runs don't duplicate the message row")
    func consecutiveRunsAreIdempotent() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _) = try await makeAccountWithInbox(database: database)

        let script = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 42)]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 43, highestModSeq: 0, messageCount: 1)]
        )
        let sessionFactory: @Sendable (IMAPConfig) -> any IMAPSessionProtocol = { config in
            FakeIMAPSession(config: config, script: script)
        }

        let first = await PushTriggeredInboxSync.run(
            accountId: account.id, uidNext: 43, fetchBodyPreview: false,
            database: database, auth: auth, sessionFactory: sessionFactory
        )
        let second = await PushTriggeredInboxSync.run(
            accountId: account.id, uidNext: 43, fetchBodyPreview: false,
            database: database, auth: auth, sessionFactory: sessionFactory
        )

        #expect(first.message?.id != nil)
        #expect(first.message?.id == second.message?.id)

        let count = try await database.dbWriter.read { db in try MessageRecord.fetchCount(db) }
        #expect(count == 1)
    }

    // MARK: (c) a subsequent normal syncAccountIncrementally (foreground resume) doesn't duplicate either

    @Test("a normal foreground-resume incremental sync after run doesn't duplicate the message row")
    func subsequentNormalIncrementalSyncDoesNotDuplicate() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _) = try await makeAccountWithInbox(database: database)

        let script = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 42)]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 43, highestModSeq: 0, messageCount: 1)]
        )
        let sessionFactory: @Sendable (IMAPConfig) -> any IMAPSessionProtocol = { config in
            FakeIMAPSession(config: config, script: script)
        }

        _ = await PushTriggeredInboxSync.run(
            accountId: account.id, uidNext: 43, fetchBodyPreview: false,
            database: database, auth: auth, sessionFactory: sessionFactory
        )

        // The app's own foreground-resume path — a completely ordinary
        // `SyncCoordinator` instance, unrelated to the one `run` used
        // internally.
        let coordinator = SyncCoordinator(database: database, sessionFactory: sessionFactory)
        _ = try await coordinator.syncAccountIncrementally(account, auth: auth, scope: .inboxOnly)

        let count = try await database.dbWriter.read { db in try MessageRecord.fetchCount(db) }
        #expect(count == 1)
    }

    // MARK: (d) auth/sync failure yields Outcome(nil, nil)

    @Test("a connect failure yields an empty Outcome instead of throwing")
    func connectFailureYieldsEmptyOutcome() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _) = try await makeAccountWithInbox(database: database)

        let script = FakeIMAPSession.Script(failConnection: .authenticationFailed(underlyingDescription: "bad password"))

        let outcome = await PushTriggeredInboxSync.run(
            accountId: account.id, uidNext: 43, fetchBodyPreview: false,
            database: database, auth: auth,
            sessionFactory: { config in FakeIMAPSession(config: config, script: script) }
        )

        #expect(outcome.message == nil)
        #expect(outcome.unreadCount == nil)
    }

    @Test("an unknown accountId yields an empty Outcome instead of crashing")
    func unknownAccountYieldsEmptyOutcome() async throws {
        let database = try AppDatabase.makeInMemory()
        let outcome = await PushTriggeredInboxSync.run(
            accountId: "does-not-exist", uidNext: 43, fetchBodyPreview: false,
            database: database, auth: auth,
            sessionFactory: { config in FakeIMAPSession(config: config, script: .init(mailboxes: [], statusByPath: [:])) }
        )
        #expect(outcome.message == nil)
        #expect(outcome.unreadCount == nil)
    }

    // MARK: (e) schedulesPostSyncPrefetch: false suppresses the launch/foreground prefetch trigger

    @Test("run never schedules the post-sync prefetch trigger, even though the just-synced message would otherwise qualify")
    func neverSchedulesPostSyncPrefetch() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _) = try await makeAccountWithInbox(database: database)

        // The pushed message (uid 42, `notFetched` since `fetchBodyPreview:
        // false` below) is itself a valid unified-inbox prefetch candidate
        // — recent, unfetched — so if `schedulesPostSyncPrefetch: false`
        // failed to suppress the trigger, `waitForPendingPostSyncPrefetchForTesting()`
        // below would return a non-`nil` count instead of `nil`.
        let script = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 42)]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 43, highestModSeq: 0, messageCount: 1)],
            bodiesByPath: ["INBOX": [42: MessageBodyContent(plainText: "本文")]]
        )
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        let outcome = await PushTriggeredInboxSync.run(
            accountId: account.id, uidNext: 43, fetchBodyPreview: false,
            database: database, auth: auth, coordinator: coordinator
        )
        #expect(outcome.message?.bodyState != .fetched, "sanity check: this message is a genuine prefetch candidate")

        let prefetchResult = await coordinator.waitForPendingPostSyncPrefetchForTesting()
        #expect(prefetchResult == nil, "schedulesPostSyncPrefetch: false must suppress the post-sync prefetch trigger entirely")
    }

    // MARK: (f) fetchBodyPreview: true persists a messageBody row

    @Test("fetchBodyPreview: true fetches and persists the target message's body")
    func fetchBodyPreviewPersistsBody() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _) = try await makeAccountWithInbox(database: database)

        let script = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 42)]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 43, highestModSeq: 0, messageCount: 1)],
            bodiesByPath: ["INBOX": [42: MessageBodyContent(plainText: "本文プレビュー")]]
        )

        let outcome = await PushTriggeredInboxSync.run(
            accountId: account.id, uidNext: 43, fetchBodyPreview: true,
            database: database, auth: auth,
            sessionFactory: { config in FakeIMAPSession(config: config, script: script) }
        )

        let messageId = try #require(outcome.message?.id)
        #expect(outcome.message?.bodyState == .fetched)

        let bodyRow = try await database.dbWriter.read { db in try MessageBodyRecord.fetchOne(db, key: messageId) }
        #expect(bodyRow?.plainText == "本文プレビュー")
    }

    @Test("fetchBodyPreview: false leaves the body notFetched")
    func fetchBodyPreviewFalseLeavesBodyUnfetched() async throws {
        let database = try AppDatabase.makeInMemory()
        let (account, _) = try await makeAccountWithInbox(database: database)

        let script = FakeIMAPSession.Script(
            mailboxes: [inboxInfo],
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 42)]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 43, highestModSeq: 0, messageCount: 1)],
            bodiesByPath: ["INBOX": [42: MessageBodyContent(plainText: "本文プレビュー")]]
        )

        let outcome = await PushTriggeredInboxSync.run(
            accountId: account.id, uidNext: 43, fetchBodyPreview: false,
            database: database, auth: auth,
            sessionFactory: { config in FakeIMAPSession(config: config, script: script) }
        )

        #expect(outcome.message?.bodyState == .notFetched)
        let messageId = try #require(outcome.message?.id)
        let bodyRow = try await database.dbWriter.read { db in try MessageBodyRecord.fetchOne(db, key: messageId) }
        #expect(bodyRow == nil)
    }
}
