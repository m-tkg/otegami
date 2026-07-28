import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// Task #80 (「直近3日200件だけでなく、検索結果など、メール一覧が更新された
/// ときに、バックグラウンドでメールを取得するようにしてほしい」): exercises
/// `SyncCoordinator.prefetchMessageBodies(messageIds:accounts:authProvider:)`
/// end to end against `FakeIMAPSession` — the general-purpose sibling to
/// `UnifiedInboxPrefetchTests`' coverage of the fixed "unified inbox, last 3
/// days" candidate set. `MessageListView`/`SearchScreenView` are this
/// method's real callers (their own debounce/list-diffing is UI state, not
/// unit-tested here — see those views' `schedulePrefetch(for:)` doc
/// comments); this suite covers everything `SyncCoordinator` itself is
/// responsible for.
@Suite("SyncCoordinator.prefetchMessageBodies")
struct MessageBodiesPrefetchTests {
    private func makeAccount(id: String, email: String, host: String = "localhost") -> AccountRecord {
        AccountRecord(
            id: id,
            displayName: email,
            email: email,
            authType: .password,
            imapHost: host,
            imapPort: 1143,
            imapSecurity: .plain,
            imapUsername: email
        )
    }

    private func insertMessage(
        database: AppDatabase,
        accountId: String,
        path: String,
        role: MailboxRoleRecord,
        uid: Int64,
        subject: String,
        internalDate: Date = Date(),
        bodyState: MessageBodyState = .notFetched
    ) async throws -> Int64 {
        try await database.dbWriter.write { db in
            var mailbox = MailboxRecord(accountId: accountId, path: path, displayPath: path, role: role)
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

    @Test("fetches only not-yet-fetched messages among the given ids, leaving already-fetched ones alone")
    func fetchesOnlyNotYetFetchedMessages() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "account-1", email: "a1@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }

        let id1 = try await insertMessage(database: database, accountId: account.id, path: "INBOX", role: .inbox, uid: 1, subject: "one")
        let id2 = try await insertMessage(database: database, accountId: account.id, path: "INBOX", role: .inbox, uid: 2, subject: "two", bodyState: .fetched)
        let id3 = try await insertMessage(database: database, accountId: account.id, path: "INBOX", role: .inbox, uid: 3, subject: "three")

        let script = FakeIMAPSession.Script(
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 3)],
            bodiesByPath: ["INBOX": [1: MessageBodyContent(plainText: "本文1"), 3: MessageBodyContent(plainText: "本文3")]]
        )
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        let fetchedCount = await coordinator.prefetchMessageBodies(messageIds: [id1, id2, id3], accounts: [account]) { _ in self.auth }
        #expect(fetchedCount == 2)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.first { $0.id == id1 }?.bodyState == .fetched)
        #expect(messages.first { $0.id == id2 }?.bodyState == .fetched) // was already fetched, untouched
        #expect(messages.first { $0.id == id3 }?.bodyState == .fetched)
    }

    @Test("spans multiple mailboxes of the same account, selecting each distinct mailboxPath once")
    func spansMultipleMailboxesOfSameAccount() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "account-1", email: "a1@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }

        // A search result mixing an INBOX hit with an Archive hit — the
        // scenario `unfetchedUnifiedInboxCandidates` never has to handle
        // (always exactly one inbox-role mailbox per account) but an
        // arbitrary search-result id list can.
        let inboxId = try await insertMessage(database: database, accountId: account.id, path: "INBOX", role: .inbox, uid: 1, subject: "inbox hit")
        let archiveId = try await insertMessage(database: database, accountId: account.id, path: "Archive", role: .all, uid: 1, subject: "archive hit")

        let script = FakeIMAPSession.Script(
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 1),
                "Archive": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 1),
            ],
            bodiesByPath: [
                "INBOX": [1: MessageBodyContent(plainText: "本文")],
                "Archive": [1: MessageBodyContent(plainText: "本文")],
            ]
        )
        // `@unchecked Sendable` + `NSLock`, same shape as
        // `UnifiedInboxPrefetchTests.HostRecorder` — `sessionFactory` is a
        // synchronous `@Sendable` closure, so stashing the one session it
        // builds for this single-account test must be synchronous too.
        final class SessionBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _session: FakeIMAPSession?
            var session: FakeIMAPSession? {
                get { lock.withLock { _session } }
                set { lock.withLock { _session = newValue } }
            }
        }
        let sessionBox = SessionBox()
        let coordinator = SyncCoordinator(database: database) { config in
            let session = FakeIMAPSession(config: config, script: script)
            sessionBox.session = session
            return session
        }

        let fetchedCount = await coordinator.prefetchMessageBodies(messageIds: [inboxId, archiveId], accounts: [account]) { _ in self.auth }
        #expect(fetchedCount == 2)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.allSatisfy { $0.bodyState == .fetched })

        // Each distinct mailboxPath selected exactly once, not once per message.
        let selected = await sessionBox.session?.selectedPaths
        #expect(selected == ["INBOX", "Archive"])
    }

    @Test("an id whose account isn't in the given accounts list is skipped")
    func skipsIdsNotOwnedByGivenAccounts() async throws {
        let database = try AppDatabase.makeInMemory()
        let knownAccount = makeAccount(id: "account-known", email: "known@otegami.test")
        let otherAccount = makeAccount(id: "account-other", email: "other@otegami.test")
        try await database.dbWriter.write { db in
            try knownAccount.insert(db)
            try otherAccount.insert(db)
        }

        let knownId = try await insertMessage(database: database, accountId: knownAccount.id, path: "INBOX", role: .inbox, uid: 1, subject: "known")
        let otherId = try await insertMessage(database: database, accountId: otherAccount.id, path: "INBOX", role: .inbox, uid: 1, subject: "other")

        let script = FakeIMAPSession.Script(
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 1)],
            bodiesByPath: ["INBOX": [1: MessageBodyContent(plainText: "本文")]]
        )
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        // Only `knownAccount` is passed — `otherId` belongs to an account
        // this call was never told about, and must not be fetched on its
        // behalf.
        let fetchedCount = await coordinator.prefetchMessageBodies(messageIds: [knownId, otherId], accounts: [knownAccount]) { _ in self.auth }
        #expect(fetchedCount == 1)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.first { $0.id == knownId }?.bodyState == .fetched)
        #expect(messages.first { $0.id == otherId }?.bodyState == .notFetched)
    }

    @Test("a connection failure (offline) is swallowed silently, no throw")
    func connectionFailureIsSilent() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "account-1", email: "a1@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }
        let id = try await insertMessage(database: database, accountId: account.id, path: "INBOX", role: .inbox, uid: 1, subject: "msg")

        let script = FakeIMAPSession.Script(failConnection: .connectionFailed(underlyingDescription: "offline"))
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        let fetchedCount = await coordinator.prefetchMessageBodies(messageIds: [id], accounts: [account]) { _ in self.auth }
        #expect(fetchedCount == 0)

        let message = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: id) }
        #expect(message?.bodyState == .notFetched)
    }

    @Test("empty messageIds or empty accounts is a harmless no-op")
    func emptyInputsNoOp() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "account-1", email: "a1@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }
        let id = try await insertMessage(database: database, accountId: account.id, path: "INBOX", role: .inbox, uid: 1, subject: "msg")

        let coordinator = SyncCoordinator(database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script())
        }

        let noIds = await coordinator.prefetchMessageBodies(messageIds: [], accounts: [account]) { _ in self.auth }
        #expect(noIds == 0)

        let noAccounts = await coordinator.prefetchMessageBodies(messageIds: [id], accounts: []) { _ in self.auth }
        #expect(noAccounts == 0)
    }

    // MARK: - Coexistence with the existing 3日/200件 unified-inbox prefetch (Task #31/#63)

    @Test("fetches a message outside the unified-inbox prefetch's 3-day window — the whole point of this being a separate, caller-driven entry point")
    func fetchesMessageOutsideThe3DayWindow() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "account-1", email: "a1@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let windowStart = now.addingTimeInterval(-SyncCoordinator.unifiedInboxPrefetchWindow)
        // 10 days old — well outside the 3-day window
        // `prefetchUnifiedInboxBodiesIfNeeded` would ever consider, but
        // exactly the kind of old search hit `SearchScreenView` can
        // legitimately surface.
        let staleId = try await insertMessage(
            database: database, accountId: account.id, path: "INBOX", role: .inbox, uid: 1, subject: "old search hit",
            internalDate: windowStart.addingTimeInterval(-7 * 24 * 60 * 60)
        )

        let script = FakeIMAPSession.Script(
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 1)],
            bodiesByPath: ["INBOX": [1: MessageBodyContent(plainText: "本文")]]
        )
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        // The 3-day pass finds nothing (too old) — confirms this scenario
        // really is outside that pass's reach, not a redundant check.
        let unifiedInboxCount = await coordinator.prefetchUnifiedInboxBodiesIfNeeded(accounts: [account], now: now) { _ in self.auth }
        #expect(unifiedInboxCount == 0)

        // The list/search-update-triggered entry point under test fetches
        // it anyway, since the caller explicitly asked for this id.
        let fetchedCount = await coordinator.prefetchMessageBodies(messageIds: [staleId], accounts: [account]) { _ in self.auth }
        #expect(fetchedCount == 1)

        let message = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: staleId) }
        #expect(message?.bodyState == .fetched)
    }

    @Test("a message already fetched by the 3-day unified-inbox prefetch is left alone by a subsequent prefetchMessageBodies call for the same id")
    func doesNotRefetchWhatTheUnifiedInboxPassAlreadyFetched() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "account-1", email: "a1@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }

        let recentId = try await insertMessage(
            database: database, accountId: account.id, path: "INBOX", role: .inbox, uid: 1, subject: "recent",
            internalDate: Date().addingTimeInterval(-3600)
        )

        let script = FakeIMAPSession.Script(
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 1)],
            bodiesByPath: ["INBOX": [1: MessageBodyContent(plainText: "本文")]]
        )
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        let unifiedInboxCount = await coordinator.prefetchUnifiedInboxBodiesIfNeeded(accounts: [account]) { _ in self.auth }
        #expect(unifiedInboxCount == 1)

        // The list/search trigger fires right after (e.g. the same message
        // is both within the unified inbox and the top of a just-updated
        // list) — must not re-fetch a body that's already there.
        let fetchedCount = await coordinator.prefetchMessageBodies(messageIds: [recentId], accounts: [account]) { _ in self.auth }
        #expect(fetchedCount == 0)

        let message = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: recentId) }
        #expect(message?.bodyState == .fetched)
    }
}
