import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// 検索の IMAP サーバーサイド SEARCH フォールバック: exercises `SyncCoordinator
/// .serverSearch(query:accounts:authProvider:timeout:)` end to end against
/// `FakeIMAPSession` — the coordinator-level counterpart to
/// `ServerSearchServiceTests`' direct actor tests. Covers what
/// `ServerSearchService` alone can't: multi-account concurrency, per-account
/// failure tolerance, and the overall timeout race (`SyncCoordinator
/// .serverSearch`'s own doc comment explains why that's implemented as an
/// unstructured-`Task` race rather than `TaskGroup` cancellation).
@Suite("SyncCoordinator server search")
struct SyncCoordinatorServerSearchTests {
    /// `port` distinguishes accounts by `IMAPConfig` (host/port/security) —
    /// the only thing a `sessionFactory` closure actually receives, no
    /// `AccountRecord`/username — so a test can script a different
    /// `FakeIMAPSession` per account.
    private func makeAccount(id: String, email: String, port: Int = 1143) -> AccountRecord {
        AccountRecord(
            id: id, displayName: email, email: email, authType: .password,
            imapHost: "localhost", imapPort: port, imapSecurity: .plain, imapUsername: email
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

    private func insertInbox(database: AppDatabase, accountId: String) async throws {
        try await database.dbWriter.write { db in
            var mailbox = MailboxRecord(accountId: accountId, path: "INBOX", displayPath: "INBOX", role: .inbox)
            try mailbox.insert(db)
        }
    }

    // MARK: (a) per-account failure tolerance

    @Test("one account's connect failure doesn't block another account's results")
    func oneAccountFailureDoesNotBlockOthers() async throws {
        let database = try AppDatabase.makeInMemory()
        let good = makeAccount(id: "good", email: "good@otegami.test", port: 1143)
        let bad = makeAccount(id: "bad", email: "bad@otegami.test", port: 1144)
        try await database.dbWriter.write { db in
            try good.insert(db)
            try bad.insert(db)
        }
        try await insertInbox(database: database, accountId: good.id)
        try await insertInbox(database: database, accountId: bad.id)

        let goodScript = FakeIMAPSession.Script(
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 1, subject: "見つかったメール")]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)],
            searchMessagesByPath: ["INBOX": [1]]
        )
        let coordinator = SyncCoordinator(database: database) { config in
            config.port == bad.imapPort
                ? FakeIMAPSession(config: config, script: .init(failConnection: .authenticationFailed(underlyingDescription: "bad creds")))
                : FakeIMAPSession(config: config, script: goodScript)
        }

        let outcome = await coordinator.serverSearch(
            query: "見つけて",
            accounts: [good, bad],
            authProvider: { account in .password(username: account.imapUsername, password: "pw") }
        )

        #expect(outcome.failedAccountIds == ["bad"])
        #expect(outcome.summaries.count == 1)
        #expect(outcome.summaries.first?.latestMessage?.subject == "見つかったメール")
        #expect(outcome.timedOut == false)
    }

    // MARK: (b) merges hits across multiple accounts, newest first

    @Test("merges hits from every account, newest first")
    func mergesHitsAcrossAccountsNewestFirst() async throws {
        let database = try AppDatabase.makeInMemory()
        let accountA = makeAccount(id: "a", email: "a@otegami.test", port: 1143)
        let accountB = makeAccount(id: "b", email: "b@otegami.test", port: 1144)
        try await database.dbWriter.write { db in
            try accountA.insert(db)
            try accountB.insert(db)
        }
        try await insertInbox(database: database, accountId: accountA.id)
        try await insertInbox(database: database, accountId: accountB.id)

        let scriptA = FakeIMAPSession.Script(
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 1, subject: "古い方")]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)],
            searchMessagesByPath: ["INBOX": [1]]
        )
        let scriptB = FakeIMAPSession.Script(
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 99, subject: "新しい方")]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 100, highestModSeq: 0, messageCount: 1)],
            searchMessagesByPath: ["INBOX": [99]]
        )
        let coordinator = SyncCoordinator(database: database) { config in
            config.port == accountA.imapPort
                ? FakeIMAPSession(config: config, script: scriptA)
                : FakeIMAPSession(config: config, script: scriptB)
        }

        let outcome = await coordinator.serverSearch(
            query: "メール",
            accounts: [accountA, accountB],
            authProvider: { account in .password(username: account.imapUsername, password: "pw") }
        )

        #expect(outcome.summaries.map { $0.latestMessage?.subject } == ["新しい方", "古い方"])
    }

    // MARK: (c) empty query / empty accounts short-circuit

    @Test("a blank query returns immediately with no results and no connections")
    func blankQueryShortCircuits() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "a", email: "a@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }
        let recorder = FakeIMAPSession.CallRecorder()
        let coordinator = SyncCoordinator(database: database) { config in
            FakeIMAPSession(config: config, script: .init(failConnection: .authenticationFailed(underlyingDescription: "bad creds")), recorder: recorder)
        }

        let outcome = await coordinator.serverSearch(
            query: "   ",
            accounts: [account],
            authProvider: { account in .password(username: account.imapUsername, password: "pw") }
        )

        #expect(outcome.summaries.isEmpty)
        #expect(outcome.failedAccountIds.isEmpty)
        #expect(recorder.connectCount == 0)
    }

    // MARK: (d) overall timeout

    @Test("a hung account times out without blocking the whole call, and is reported as failed")
    func hungAccountTimesOut() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "slow", email: "slow@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }
        try await insertInbox(database: database, accountId: account.id)

        // `searchMessagesGate` is never `.open()`ed, so `searchMessages`
        // hangs forever — models an unreachable/hung server. Any positive
        // timeout is deterministic here (not a race against real time):
        // this side of the race can never resolve on its own, so the sleep
        // side always wins regardless of how short it is.
        let gate = FakeIMAPSession.AsyncCallGate()
        let script = FakeIMAPSession.Script(
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0)],
            searchMessagesGate: gate
        )
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        let outcome = await coordinator.serverSearch(
            query: "止まる",
            accounts: [account],
            authProvider: { account in .password(username: account.imapUsername, password: "pw") },
            timeout: .milliseconds(20)
        )

        #expect(outcome.timedOut == true)
        #expect(outcome.summaries.isEmpty)
        #expect(outcome.failedAccountIds.isEmpty, "the account never actually reported failure — it just never reported at all")
    }

    @Test("every account finishing well before the timeout returns promptly, not after waiting the full budget")
    func fastAccountsReturnBeforeTimeout() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(id: "fast", email: "fast@otegami.test")
        try await database.dbWriter.write { db in try account.insert(db) }
        try await insertInbox(database: database, accountId: account.id)

        let script = FakeIMAPSession.Script(
            envelopesByPath: ["INBOX": [makeEnvelope(uid: 1, subject: "速い")]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)],
            searchMessagesByPath: ["INBOX": [1]]
        )
        let coordinator = SyncCoordinator(database: database) { config in FakeIMAPSession(config: config, script: script) }

        let start = Date()
        let outcome = await coordinator.serverSearch(
            query: "速い",
            accounts: [account],
            authProvider: { account in .password(username: account.imapUsername, password: "pw") },
            timeout: .seconds(20)
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(outcome.timedOut == false)
        #expect(outcome.summaries.count == 1)
        #expect(elapsed < 5, "must not wait anywhere near the 20s budget once every account already reported in")
    }
}
