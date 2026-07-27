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

    // MARK: - Task #44 (実機バグ: Gmail の「すべてのメール」に新着が反映されない)

    /// Locks in the exact scenario from the real-device bug report at the
    /// `FakeIMAPSession` level: a `role: .all` mailbox (what this app maps
    /// Gmail's IMAP `\All` SPECIAL-USE "すべてのメール" to —
    /// `MailCoreIMAPSession+Mapping.role(for:path:)`), synced via
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
}
