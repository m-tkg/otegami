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

    /// Real-device repro (docs/verify.md, "実機バグ調査: 疎な UID 帯を持つ
    /// メールボックスで初期同期が0通になる"): a real Gmail/iCloud account's
    /// `uidNext` reflects every message ever placed in this mailbox
    /// (including ones since archived/deleted), not how many are currently
    /// present. A mailbox that has processed thousands of messages over its
    /// history but currently holds only a handful of *old* survivors (never
    /// archived, everything newer already was) has a huge gap between
    /// `uidNext` and those survivors' UIDs — exactly the shape
    /// `IMAPSessionProtocol.fetchRecentEnvelopes`'s doc comment warns
    /// against (a UID-range window assumes the UID space is dense). This
    /// models that: `uidNext` is 4000
    /// (thousands of historical messages), but only 5 messages currently
    /// exist, at UIDs 1990...1994 — an "old band" nowhere near `1`
    /// (ruling out the function's `else 1` branch accidentally saving it)
    /// and nowhere near `uidNext` either.
    @Test("initial sync still finds a mailbox's current messages when they sit in an old, sparse UID band far from uidNext")
    func fetchesSparseOldUIDBand() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let survivingUIDs: [UInt32] = [1990, 1991, 1992, 1993, 1994]
        let envelopes = survivingUIDs.map { makeInbox(uid: $0, subject: "msg-\($0)") }
        let script = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": envelopes],
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: 4000, highestModSeq: 0, messageCount: survivingUIDs.count),
            ]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: script)
        }

        let progress = try await syncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))
        #expect(progress.envelopesFetched == survivingUIDs.count)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == survivingUIDs.count)
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
        // `autoRetry: false`: this test's Junk failure is deterministic
        // (missing `statusByPath` entry, same every attempt) — without
        // this, Task #69's automatic retry would spend ~30s of real
        // backoff sleeps retrying a failure that can never succeed, before
        // this test could even get to its assertions.
        let progress = try await syncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"), autoRetry: false)
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
        // `autoRetry: false`: same rationale as the sibling test above —
        // this deterministic failure would otherwise cost ~30s of real
        // Task #69 backoff sleeps for no test value.
        _ = try await syncer.performInitialSync(auth: auth, autoRetry: false)

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

    // MARK: - メールボックス単位の非表示

    /// A full manual refresh (`.all`) must skip a hidden mailbox — see
    /// `MailboxRecord.isHidden`'s doc comment ("同期も止める", battery/
    /// network cost). `.inboxOnly` isn't covered here since it only ever
    /// targets INBOX/Drafts regardless of any mailbox's `isHidden`.
    @Test(".all scope skips a hidden mailbox but still syncs a visible one")
    func allScopeSkipsHiddenMailbox() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let archive = MailboxInfo(path: "Archive", displayPath: "Archive", role: .archive, attributes: [])

        let initialSyncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inbox, archive],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "Archive": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                ]
            ))
        }
        _ = try await initialSyncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        let archiveMailboxId = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "Archive").fetchOne(db)?.id
            }
        )
        try await database.dbWriter.write { db in
            try MailboxQuery.setHidden(mailboxId: archiveMailboxId, hidden: true, db: db)
        }

        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox, archive],
            envelopesByPath: [
                "INBOX": [makeInbox(uid: 1, subject: "INBOX新着")],
                "Archive": [makeInbox(uid: 1, subject: "Archive新着")],
            ],
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1),
                "Archive": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1),
            ]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        _ = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"), scope: .all)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.contains { $0.subject == "INBOX新着" }, "Visible mailbox should still be synced by .all")
        #expect(!messages.contains { $0.subject == "Archive新着" }, "Hidden mailbox must be skipped by .all")

        // The hidden mailbox's own row still got re-listed/upserted (it's
        // not simply absent from `mailbox`) — just excluded from the sync
        // *targets*. `isHidden` itself must have survived that re-upsert.
        let archiveAfter = try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: archiveMailboxId) }
        #expect(archiveAfter?.isHidden == true)
    }

    /// `AccountSyncer.upsertMailboxes` runs on *every* sync pass (initial,
    /// incremental, IDLE-triggered), re-listing and re-upserting every
    /// mailbox `IMAP LIST` reports — without `Column("isHidden")
    /// .noOverwrite`, the freshly-constructed `MailboxRecord` (always
    /// `isHidden: false`, since it has no way to know the user's choice)
    /// would silently un-hide a mailbox on its very next sync.
    @Test("a hidden mailbox stays hidden across a later .inboxOnly sync that re-lists it")
    func hiddenMailboxSurvivesResync() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let archive = MailboxInfo(path: "Archive", displayPath: "Archive", role: .archive, attributes: [])

        let initialSyncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inbox, archive],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "Archive": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                ]
            ))
        }
        _ = try await initialSyncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))
        let archiveMailboxId = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "Archive").fetchOne(db)?.id
            }
        )
        try await database.dbWriter.write { db in
            try MailboxQuery.setHidden(mailboxId: archiveMailboxId, hidden: true, db: db)
        }

        // `.inboxOnly` — the frequent/IDLE-wake path — still re-lists every
        // mailbox via `listMailboxes()`/`upsertMailboxes` before narrowing
        // down to its actual sync targets.
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inbox, archive],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "Archive": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                ]
            ))
        }
        _ = try await syncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        let archiveAfter = try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: archiveMailboxId) }
        #expect(archiveAfter?.isHidden == true, "A resync must not silently un-hide a mailbox")
    }

    // MARK: - Task #119 (実機報告「その他 → Trash」)

    /// The other half of Task #119's fix: `MailboxRole.inferred(fromDisplayPath:)`
    /// (`packages/OtegamiKit/Sources/MailTransport/MailboxRoleNameInference.swift`)
    /// only fixes mailboxes discovered *after* the fix ships — a mailbox
    /// that was already stored locally with `role == .none` (from before
    /// this app version existed, back when a SPECIAL-USE-less Trash always
    /// fell through to "その他") also needs to self-heal on its own, without
    /// requiring `uidValidity` to change or the user to do anything special.
    /// `upsertMailboxes` (unlike `Column("isHidden").noOverwrite` right
    /// above) deliberately does *not* protect `role` from being overwritten
    /// on every sync pass — this test locks that in: a mailbox stored with
    /// the pre-fix `role: .none` gets corrected to `.trash` the very next
    /// time `performIncrementalSync` re-lists mailboxes, same `uidValidity`
    /// throughout.
    @Test("a locally-stored role is re-evaluated (not frozen) on every later mailbox re-sync")
    func mailboxRoleIsReevaluatedOnResync() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        // Simulates a mailbox this app previously discovered before Task
        // #119's name-based fallback existed: no SPECIAL-USE attribute the
        // old `role(for:path:)` recognized, so it was stored as `.none`.
        let trash = MailboxInfo(path: "Trash", displayPath: "Trash", role: .none, attributes: [])

        let initialSyncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inbox, trash],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "Trash": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                ]
            ))
        }
        _ = try await initialSyncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))
        let trashMailboxId = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "Trash").fetchOne(db)?.id
            }
        )
        let trashBefore = try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: trashMailboxId) }
        // `MailboxRoleRecord.none` explicitly, not bare `.none` — the latter
        // resolves to `Optional<MailboxRoleRecord>.none` (nil) instead of
        // `.some(.none)` in this `T?`-typed comparison, the classic Swift
        // "wrapped type also has a case named `none`" footgun.
        #expect(trashBefore?.role == MailboxRoleRecord.none, "precondition: this test simulates a mailbox stored before the name-based fallback existed")

        // A later sync pass re-lists the same mailbox, this time with the
        // fixed role-inference logic reporting `.trash` — same `uidValidity`
        // (1), so this doesn't take the uidValidity-changed full-resync path
        // at all; it's the ordinary `upsertMailboxes` re-upsert every
        // incremental sync already does.
        let fixedTrash = MailboxInfo(path: "Trash", displayPath: "Trash", role: .trash, attributes: [])
        let resyncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inbox, fixedTrash],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                    "Trash": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
                ]
            ))
        }
        _ = try await resyncer.performIncrementalSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        let trashAfter = try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: trashMailboxId) }
        #expect(trashAfter?.role == .trash, "a stale locally-stored role must be corrected by the next mailbox re-sync, not frozen at its first-ever value")
    }

    // MARK: - Task #44 (実機バグ: Gmail の「すべてのメール」に新着が反映されない)

    /// Locks in the exact scenario from the real-device bug report at the
    /// `FakeIMAPSession` level: a `role: .all` mailbox (what this app maps
    /// Gmail's IMAP `\All` SPECIAL-USE "すべてのメール" to —
    /// `MailCoreIMAPSession+Mapping.role(for:path:displayPath:)`), synced via
    /// `.mailbox(path:)` — exactly what `MessageListView.refresh()`'s
    /// `.mailbox` case (pull-to-refresh, and now also the "開いた時" sync
    /// `MessageListView.syncSelectedMailboxOnAppear()` added) does for a
    /// single selected non-INBOX mailbox — with a real (CONDSTORE-capable)
    /// server response shape, must pick up new mail that arrived after the
    /// last sync. The same shape is also confirmed against a real Dovecot
    /// in `SyncEngineIntegrationTests
    /// .mailboxScopedIncrementalSyncPicksUpNewMailInNonInboxMailbox` — this
    /// test is the fast, no-Docker-required counterpart that keeps running
    /// in `make test`/CI.
    @Test(".mailbox(path:) scope picks up new mail in a role-.all (Gmail \"すべてのメール\") mailbox, CONDSTORE capable")
    func mailboxScopedSyncPicksUpNewMailInAllMailRoleMailbox() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let allMail = MailboxInfo(path: "[Gmail]/All Mail", displayPath: "[Gmail]/すべてのメール", role: .all, attributes: [])

        let initialSyncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script(
                mailboxes: [inbox, allMail],
                envelopesByPath: [
                    "INBOX": [makeInbox(uid: 1, subject: "INBOX既存")],
                    "[Gmail]/All Mail": [makeInbox(uid: 1, subject: "AllMail既存")],
                ],
                statusByPath: [
                    "INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 5, messageCount: 1),
                    "[Gmail]/All Mail": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 5, messageCount: 1),
                ],
                capabilitiesToReport: [.condstore]
            ))
        }
        _ = try await initialSyncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        let allMailMailboxId = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "[Gmail]/All Mail").fetchOne(db)?.id
            }
        )

        // New mail lands in INBOX *and* (this app's simulation of Gmail
        // having finished indexing it into the virtual "すべてのメール"
        // view) All Mail — highestModSeq unchanged, isolating this to the
        // new-mail step exactly like `MailboxSyncerTests.fetchesNewMailOnly`.
        let incrementalScript = FakeIMAPSession.Script(
            mailboxes: [inbox, allMail],
            envelopesByPath: [
                "INBOX": [makeInbox(uid: 2, subject: "INBOX新着")],
                "[Gmail]/All Mail": [makeInbox(uid: 2, subject: "AllMail新着")],
            ],
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: 3, highestModSeq: 5, messageCount: 2),
                "[Gmail]/All Mail": MailboxStatus(uidValidity: 1, uidNext: 3, highestModSeq: 5, messageCount: 2),
            ],
            capabilitiesToReport: [.condstore]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: incrementalScript)
        }
        // Exactly the scope a sidebar selection of "すべてのメール" (or its
        // pull-to-refresh / 開いた時 sync) uses — *not* `.all`/`.inboxOnly`.
        let progress = try await syncer.performIncrementalSync(
            auth: .password(username: "test1@otegami.test", password: "test1234"),
            scope: .mailbox(path: "[Gmail]/All Mail")
        )
        #expect(progress.newMessages == 1)
        #expect(progress.didFullResync == false)

        let allMailMessages = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == allMailMailboxId).fetchAll(db)
        }
        #expect(allMailMessages.count == 2, "the new All Mail message must be picked up even though INBOX wasn't in scope")
        #expect(allMailMessages.contains { $0.subject == "AllMail新着" })

        // `.mailbox(path:)` must not have touched INBOX at all (out of
        // scope) — confirms this test's scoping actually exercised the
        // single-mailbox path, not a broader one.
        let inboxMailboxId = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "INBOX").fetchOne(db)?.id
            }
        )
        let inboxMessages = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == inboxMailboxId).fetchAll(db)
        }
        #expect(inboxMessages.count == 1, "INBOX must be untouched by a .mailbox(path:) scope targeting a different mailbox")
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
