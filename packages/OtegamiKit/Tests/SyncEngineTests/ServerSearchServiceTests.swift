import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// 検索の IMAP サーバーサイド SEARCH フォールバック: direct scenario tests for
/// `ServerSearchService`, the same "build the actor directly, drive it
/// against a scripted `FakeIMAPSession`" shape `BackfillSyncerTests` uses
/// for `BackfillSyncer`. `ServerSearchService.search` doesn't itself
/// `connect` (the caller — `SyncCoordinator` in production — already did),
/// so these tests call it directly against a bare `FakeIMAPSession` without
/// going through `SyncCoordinator` at all.
@Suite("ServerSearchService")
struct ServerSearchServiceTests {
    private func makeAccount(kind: AccountKind = .generic) -> AccountRecord {
        AccountRecord(
            displayName: "Test", email: "test@otegami.test", authType: .password, kind: kind,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test@otegami.test"
        )
    }

    private func makeEnvelope(uid: UInt32, subject: String) -> FetchedEnvelope {
        FetchedEnvelope(
            uid: uid,
            messageId: "<seed-\(uid)@otegami.test>",
            inReplyTo: nil,
            references: [],
            subject: subject,
            from: [EmailAddress(name: "Aiko", address: "aiko@otegami.test")],
            to: [EmailAddress(address: "test@otegami.test")],
            cc: [], bcc: [], replyTo: [],
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            internalDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            flags: [],
            size: 512
        )
    }

    @discardableResult
    private func makeMailbox(
        database: AppDatabase, account: AccountRecord, path: String = "INBOX", role: MailboxRoleRecord = .inbox
    ) async throws -> MailboxRecord {
        try await database.dbWriter.write { db in
            var mailbox = MailboxRecord(accountId: account.id, path: path, displayPath: path, role: role)
            try mailbox.insert(db)
            return mailbox
        }
    }

    // MARK: (a) unknown UID ingestion

    @Test("a UID the server reports that isn't local yet gets fetched and upserted, and its message id is included")
    func ingestsUnknownUID() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let mailbox = try await makeMailbox(database: database, account: account)

        let session = FakeIMAPSession(config: account.imapConfig, script: FakeIMAPSession.Script(
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 42, subject: "サーバーにしかないメール")]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 43, highestModSeq: 0, messageCount: 1)],
            searchMessagesByPath: ["INBOX": [42]]
        ))
        let service = ServerSearchService(database: database)

        let summaries = try await service.search(account: account, query: "見つけて", session: session)

        #expect(summaries.count == 1)
        #expect(summaries.first?.latestMessage?.subject == "サーバーにしかないメール")

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == 1, "the previously-unknown UID must now be persisted locally")
        #expect(messages.first?.uid == 42)
        #expect(messages.first?.mailboxId == mailbox.id)
    }

    // MARK: (b) already-local hit needs no re-fetch

    @Test("a UID the server reports that's already local is included without any fetchEnvelopes call")
    func includesExistingLocalHitWithoutRefetch() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let mailbox = try await makeMailbox(database: database, account: account)
        try await database.dbWriter.write { db in
            var message = MessageRecord(mailboxId: mailbox.id!, uid: 7, subject: "既にローカルにあるメール", internalDate: Date())
            try message.insert(db)
        }

        // No `envelopesByPath` scripted at all — if `search` incorrectly
        // tried to re-fetch UID 7, `fetchEnvelopes` would just return `[]`
        // (not throw), so this also confirms via `fetchEnvelopesSetCalls`
        // below that no fetch was even attempted.
        let session = FakeIMAPSession(config: account.imapConfig, script: FakeIMAPSession.Script(
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 8, highestModSeq: 0, messageCount: 1)],
            searchMessagesByPath: ["INBOX": [7]]
        ))
        let service = ServerSearchService(database: database)

        let summaries = try await service.search(account: account, query: "既に", session: session)

        #expect(summaries.count == 1)
        #expect(summaries.first?.latestMessage?.uid == 7)

        let setCalls = await session.fetchEnvelopesSetCalls
        #expect(setCalls.isEmpty, "an already-local UID must not trigger a fetchEnvelopes(uids: UIDSet) call")
    }

    // MARK: (c) per-mailbox cap

    @Test("only the highest maxHitsPerMailbox UIDs are ingested when the server returns more than the cap")
    func capsHitsPerMailbox() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        try await makeMailbox(database: database, account: account)

        // 10 UIDs found server-side, cap set to 3 — only the 3 largest
        // (newest, per the UID-as-recency-proxy approximation) should be
        // fetched.
        let allUIDs: Set<UInt32> = Set(1...10)
        let script = FakeIMAPSession.Script(
            envelopesByPath: ["INBOX": (1...10).map { makeEnvelope(uid: $0, subject: "msg-\($0)") }],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 11, highestModSeq: 0, messageCount: 10)],
            searchMessagesByPath: ["INBOX": allUIDs]
        )
        let session = FakeIMAPSession(config: account.imapConfig, script: script)
        let service = ServerSearchService(database: database, maxHitsPerMailbox: 3)

        let summaries = try await service.search(account: account, query: "cap", session: session)

        #expect(summaries.count == 3)
        #expect(Set(summaries.compactMap { $0.latestMessage?.uid }) == [8, 9, 10])

        let setCalls = await session.fetchEnvelopesSetCalls
        #expect(setCalls.count == 1)
        #expect(Set(setCalls[0].uids.uids) == [8, 9, 10])
    }

    // MARK: (d) failure propagation (account-level tolerance lives in SyncCoordinator)

    @Test("a search failure on one mailbox throws rather than being silently swallowed")
    func searchFailurePropagates() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        try await makeMailbox(database: database, account: account)

        let session = FakeIMAPSession(config: account.imapConfig, script: FakeIMAPSession.Script(
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0)],
            failSearchMessages: .serverError(underlyingDescription: "SEARCH failed")
        ))
        let service = ServerSearchService(database: database)

        await #expect(throws: Error.self) {
            _ = try await service.search(account: account, query: "boom", session: session)
        }
    }

    // MARK: (e) Gmail All Mail targeting

    @Test("a Gmail account with a local All Mail mailbox is searched only there")
    func gmailAccountSearchesOnlyAllMail() async throws {
        let allMail = MailboxRecord(accountId: "a", path: "[Gmail]/All Mail", displayPath: "All Mail", role: .all)
        let inbox = MailboxRecord(accountId: "a", path: "INBOX", displayPath: "INBOX", role: .inbox)
        let targets = ServerSearchService.searchTargets(mailboxes: [inbox, allMail], isGmail: true)
        #expect(targets.map(\.path) == ["[Gmail]/All Mail"])
    }

    @Test("a Gmail account with no local All Mail mailbox yet falls back to every mailbox")
    func gmailAccountWithoutAllMailFallsBackToEveryMailbox() async throws {
        let inbox = MailboxRecord(accountId: "a", path: "INBOX", displayPath: "INBOX", role: .inbox)
        let sent = MailboxRecord(accountId: "a", path: "[Gmail]/Sent Mail", displayPath: "Sent", role: .sent)
        let targets = ServerSearchService.searchTargets(mailboxes: [inbox, sent], isGmail: true)
        #expect(Set(targets.map(\.path)) == ["INBOX", "[Gmail]/Sent Mail"])
    }

    @Test("a non-Gmail account is always searched across every mailbox, All Mail role or not")
    func nonGmailAccountSearchesEveryMailbox() async throws {
        let inbox = MailboxRecord(accountId: "a", path: "INBOX", displayPath: "INBOX", role: .inbox)
        let archive = MailboxRecord(accountId: "a", path: "Archive", displayPath: "Archive", role: .archive)
        let targets = ServerSearchService.searchTargets(mailboxes: [inbox, archive], isGmail: false)
        #expect(Set(targets.map(\.path)) == ["INBOX", "Archive"])
    }

    // MARK: (f) hidden mailboxes are excluded

    @Test("a hidden mailbox is never searched")
    func hiddenMailboxIsExcluded() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        try await database.dbWriter.write { db in
            var hidden = MailboxRecord(accountId: account.id, path: "Muted", displayPath: "Muted", role: .none, isHidden: true)
            try hidden.insert(db)
        }

        let session = FakeIMAPSession(config: account.imapConfig, script: FakeIMAPSession.Script(
            failSearchMessages: .serverError(underlyingDescription: "should never be called")
        ))
        let service = ServerSearchService(database: database)

        let summaries = try await service.search(account: account, query: "muted", session: session)
        #expect(summaries.isEmpty)

        let calls = await session.searchMessagesCalls
        #expect(calls.isEmpty)
    }
}
