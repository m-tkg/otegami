import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

@Suite("AccountSyncer initial sync")
struct AccountSyncerTests {
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

    @Test("fetches envelopes into message/messageReference on initial sync")
    func fetchesEnvelopesIntoStore() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let envelopes = [
            makeInbox(uid: 1, subject: "ようこそ otegami へ"),
            makeInbox(uid: 2, subject: "明日の打ち合わせについて"),
            makeInbox(uid: 3, subject: "Re: 明日の打ち合わせについて", references: ["<seed-2@otegami.test>"]),
        ]
        let script = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": envelopes],
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: 4, highestModSeq: 0, messageCount: 3),
            ]
        )

        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: script)
        }

        let progress = try await syncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))
        #expect(progress.mailboxesDiscovered == 1)
        #expect(progress.envelopesFetched == 3)

        let (mailboxes, messages) = try await database.dbWriter.read { db in
            (
                try MailboxRecord.filter(Column("accountId") == account.id).fetchAll(db),
                try MessageRecord.fetchAll(db)
            )
        }
        #expect(mailboxes.count == 1)
        #expect(mailboxes.first?.role == .inbox)
        #expect(mailboxes.first?.messageCount == 3)
        #expect(mailboxes.first?.uidNext == 4)
        #expect(mailboxes.first?.lastSyncedAt != nil)

        #expect(messages.count == 3)
        let subjects = Set(messages.compactMap(\.subject))
        #expect(subjects.contains("ようこそ otegami へ"))
        #expect(subjects.contains("Re: 明日の打ち合わせについて"))

        let reply = try #require(messages.first { $0.subject == "Re: 明日の打ち合わせについて" })
        let references = try await database.dbWriter.read { db in
            try MessageReferenceRecord.filter(Column("messageId") == reply.id).fetchAll(db)
        }
        #expect(references.map(\.referenceValue) == ["<seed-2@otegami.test>"])
    }

    @Test("resyncing the same mailbox is idempotent and picks up flag changes")
    func resyncIsIdempotent() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        var envelope = makeInbox(uid: 1, subject: "ようこそ otegami へ")
        let firstScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": [envelope]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)]
        )

        let syncer1 = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: firstScript)
        }
        _ = try await syncer1.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        // Second sync: server now reports the message as \Seen.
        envelope.flags = .seen
        let secondScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": [envelope]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)]
        )
        let syncer2 = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: secondScript)
        }
        _ = try await syncer2.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == 1)
        #expect(messages.first?.flags.contains(.seen) == true)

        let mailboxes = try await database.dbWriter.read { db in try MailboxRecord.fetchAll(db) }
        #expect(mailboxes.count == 1)
    }

    @Test("only fetches the most recent initialSyncWindow messages from a larger mailbox")
    func fetchesOnlyRecentWindow() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let totalMessages: UInt32 = 600
        let envelopes = (1...totalMessages).map { makeInbox(uid: $0, subject: "msg-\($0)") }
        let script = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": envelopes],
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: totalMessages + 1, highestModSeq: 0, messageCount: Int(totalMessages)),
            ]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: script)
        }

        let progress = try await syncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))
        #expect(progress.envelopesFetched == Int(AccountSyncer.initialSyncWindow))

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == Int(AccountSyncer.initialSyncWindow))
        let uids = messages.map(\.uid).sorted()
        #expect(uids.first == Int64(totalMessages - AccountSyncer.initialSyncWindow + 1))
        #expect(uids.last == Int64(totalMessages))
    }

    @Test("a later mailbox failing to select doesn't leave an earlier mailbox's messages unthreaded")
    func laterMailboxFailureDoesNotBlockEarlierMailboxThreading() async throws {
        // Regression test for a real-device bug: `performInitialSync`
        // iterates every selectable mailbox in one loop and only calls
        // `ThreadAssigner.assignAllUnthreaded` once, at the very end. If a
        // *later* mailbox's `select` throws (a transient network error —
        // far more likely on a real Wi-Fi path than the dev mailstack's
        // loopback, which is why this didn't reproduce in simulator
        // testing), the whole function used to throw before ever reaching
        // that final call, silently (callers use `try?`) leaving every
        // envelope an *earlier* mailbox (INBOX here) already fetched
        // permanently unthreaded — invisible in both the unified inbox and
        // the account's own mailbox view, even though the mailbox's own
        // `uidNext` already looks fully synced.
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        // No SPECIAL-USE role required for the repro — any second
        // selectable mailbox the fake server "fails" to SELECT works.
        let junk = MailboxInfo(path: "Junk", displayPath: "Junk", role: .junk, attributes: [])
        let envelopes = [makeInbox(uid: 1, subject: "ようこそ otegami へ")]
        let script = FakeIMAPSession.Script(
            mailboxes: [inbox, junk],
            envelopesByPath: ["INBOX": envelopes],
            // Deliberately omits "Junk" from `statusByPath`: FakeIMAPSession
            // .status(_:) throws `.mailboxNotFound` for any path not in this
            // map, which `select(_:)` calls through to — scripting exactly
            // a mid-loop SELECT failure without needing a dedicated
            // failure-injection field.
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1),
            ]
        )

        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: script)
        }

        // Must not throw: a mailbox's own sync error is swallowed per-
        // mailbox now, not propagated out of the whole initial sync.
        let progress = try await syncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))
        #expect(progress.envelopesFetched == 1)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message.threadId != nil)

        let inboxMailboxId = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "INBOX").fetchOne(db)?.id
            }
        )
        let threads = try await database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: inboxMailboxId).fetchAll(db)
        }
        #expect(threads.count == 1)

        // docs/qa-findings.md's partial-sync-failure visibility follow-up:
        // the Junk mailbox's SELECT failure above is no longer *silently*
        // swallowed (bare `continue`) — it's recorded onto that mailbox's
        // own row so `MailboxSyncFailuresView`'s sidebar banner can surface
        // it. INBOX, which synced fine, must have neither field set.
        let junkRecord = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "Junk").fetchOne(db)
            }
        )
        #expect(junkRecord.lastSyncError != nil)
        #expect(junkRecord.lastSyncErrorAt != nil)

        let inboxRecord = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "INBOX").fetchOne(db)
            }
        )
        #expect(inboxRecord.lastSyncError == nil)
        #expect(inboxRecord.lastSyncErrorAt == nil)
    }

    @Test("a mailbox's recorded sync failure clears itself once a later sync of that mailbox succeeds")
    func mailboxSyncFailureClearsOnNextSuccess() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let junk = MailboxInfo(path: "Junk", displayPath: "Junk", role: .junk, attributes: [])

        // Pass 1: Junk fails to SELECT (omitted from statusByPath, same
        // technique as the sibling test above) — should record a failure.
        let firstScript = FakeIMAPSession.Script(
            mailboxes: [inbox, junk],
            envelopesByPath: ["INBOX": [makeInbox(uid: 1, subject: "ようこそ otegami へ")]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: firstScript)
        }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")
        _ = try await syncer.performInitialSync(auth: auth)

        let junkAfterFailure = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "Junk").fetchOne(db)
            }
        )
        #expect(junkAfterFailure.lastSyncError != nil)

        // Pass 2: same syncer (a fresh `AccountSyncer` isn't required —
        // `performInitialSync` is safe to call again, its own doc comment),
        // now with Junk's status scripted so its SELECT succeeds.
        let secondScript = FakeIMAPSession.Script(
            mailboxes: [inbox, junk],
            envelopesByPath: ["INBOX": [makeInbox(uid: 1, subject: "ようこそ otegami へ")]],
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1),
                "Junk": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
            ]
        )
        let secondSyncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: secondScript)
        }
        _ = try await secondSyncer.performInitialSync(auth: auth)

        let junkAfterRecovery = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "Junk").fetchOne(db)
            }
        )
        #expect(junkAfterRecovery.lastSyncError == nil)
        #expect(junkAfterRecovery.lastSyncErrorAt == nil)
    }

    // MARK: - Account-level connect failure (account edit UI)

    /// `AccountRecord.lastSyncError`'s doc comment: a wrong password (the
    /// account-edit "save a bad password, see it fail visibly" flow) fails
    /// at `connect()`, before any mailbox is even selected — this must
    /// surface on the `account` row itself, not just (as
    /// `MailboxRecord.lastSyncError` alone would give) silently nowhere.
    @Test("a connect failure records itself on the account row")
    func connectFailureRecordsAccountLevelSyncError() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let script = FakeIMAPSession.Script(failConnection: .authenticationFailed(underlyingDescription: "bad password"))
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: script)
        }

        await #expect(throws: (any Error).self) {
            try await syncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "wrong"))
        }

        let row = try #require(
            try await database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) }
        )
        #expect(row.lastSyncError != nil)
        #expect(row.lastSyncErrorAt != nil)
    }

    @Test("an account-level connect failure clears itself once a later sync connects successfully")
    func connectFailureClearsOnNextSuccess() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let failingScript = FakeIMAPSession.Script(failConnection: .authenticationFailed(underlyingDescription: "bad password"))
        let firstSyncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: failingScript)
        }
        await #expect(throws: (any Error).self) {
            try await firstSyncer.performInitialSync(auth: auth)
        }
        let afterFailure = try #require(
            try await database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) }
        )
        #expect(afterFailure.lastSyncError != nil)

        // A fresh `AccountSyncer` isn't required for the fix to take
        // effect (in the real app it wouldn't be reused either — see
        // `SyncCoordinator.invalidateSyncer(for:)`'s doc comment — but this
        // test only cares about `AccountSyncer`'s own recover-on-success
        // behavior, independent of that).
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let succeedingScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0)]
        )
        let secondSyncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: succeedingScript)
        }
        _ = try await secondSyncer.performInitialSync(auth: auth)

        let afterRecovery = try #require(
            try await database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) }
        )
        #expect(afterRecovery.lastSyncError == nil)
        #expect(afterRecovery.lastSyncErrorAt == nil)
    }

    @Test("initialSyncLowerBound math")
    func initialSyncLowerBoundMath() {
        // Fewer messages than the window: start from UID 1.
        #expect(AccountSyncer.initialSyncLowerBound(uidNext: 10, window: 500) == 1)
        // Exactly the window: start from UID 1.
        #expect(AccountSyncer.initialSyncLowerBound(uidNext: 501, window: 500) == 1)
        // More than the window: keep only the most recent `window`.
        #expect(AccountSyncer.initialSyncLowerBound(uidNext: 601, window: 500) == 101)
    }
}
