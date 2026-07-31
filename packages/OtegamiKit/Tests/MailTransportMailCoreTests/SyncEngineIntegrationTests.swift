import Foundation
import GRDB
import Testing
@testable import MailTransportMailCore
import MailTransport
import OtegamiStore
import SyncEngine

/// M3 integration coverage: `AccountSyncer.performIncrementalSync` against
/// the real dev mailstack Dovecot, with `doveadm` (via `DoveadmHelper`)
/// standing in for a second IMAP client making concurrent changes — the
/// scenario `SyncEngineTests`' `FakeIMAPSession`-driven suite can only
/// simulate by construction, not actually exercise over the wire (real
/// `FETCH`/`STORE` framing, `CONDSTORE` support or its absence as this
/// particular Dovecot build actually advertises it, ...).
///
/// Opt-in like the rest of this target: skipped unless
/// `OTEGAMI_TEST_IMAP_HOST` is set. Run with:
///
/// ```sh
/// make mailstack-up
/// OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter SyncEngineIntegrationTests
/// make mailstack-down
/// ```
// `.serialized`: every test in this suite drives the *same* real INBOX
// (test1@otegami.test) via destructive doveadm operations
// (expunge/save/restoreStandardFixtures) — Swift Testing runs a suite's
// tests concurrently by default, which would otherwise race two tests'
// doveadm calls against the same mailbox.
@Suite(
    "SyncEngine incremental sync against dev mailstack",
    .enabled(if: TestIMAPEnvironment.primary != nil, "set OTEGAMI_TEST_IMAP_HOST to run"),
    .serialized
)
struct SyncEngineIntegrationTests {
    @Test("incrementalSync picks up new mail and a flag change made by another client (doveadm)")
    func incrementalSyncPicksUpExternalChanges() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let user = "test1@otegami.test"

        // This test's own expunge/save calls replace INBOX's contents
        // wholesale — restore the canonical seed fixtures afterward so
        // `MailCoreIMAPSessionIntegrationTests` (which assumes them) isn't
        // affected by run order within the same `swift test` invocation.
        defer { try? DoveadmHelper.restoreStandardFixtures() }

        // A known starting point (exactly one message), independent of
        // whatever `make mailstack-seed` last left in this INBOX.
        try DoveadmHelper.expungeAll(user: user)
        try DoveadmHelper.save(user: user, content: Self.sampleMessage(uid: "int-seed", subject: "integration seed"))

        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Integration",
            email: user,
            authType: .password,
            imapHost: env.host,
            imapPort: env.port,
            imapSecurity: ConnectionSecurityRecord(env.imapConfig.security),
            imapAllowsInsecureTLS: env.imapConfig.allowsInsecureTLS,
            imapUsername: user
        )
        try await database.dbWriter.write { db in try account.insert(db) }

        let syncer = AccountSyncer(account: account, database: database) { config in
            MailCoreIMAPSession(config: config)
        }
        _ = try await syncer.performInitialSync(auth: env.auth)

        // Scoped to INBOX's own mailboxId, not the whole account: this dev
        // mailstack's Dovecot is a shared, persistent server across every
        // opt-in integration test in this target, and `performInitialSync`
        // now correctly syncs *every* selectable mailbox including Sent
        // (docs/verify.md, "実機バグ調査: 疎な UID 帯を持つメールボックスで初期同期が
        // 0通になる" — before that fix, a UID-window initial sync of a
        // mailbox like Sent with a sparse/gappy UID history from unrelated
        // prior test runs could silently fetch 0 and mask exactly this kind
        // of cross-test leftover; scoping this assertion to INBOX is the
        // correct fix now that Sent/Drafts/etc. are reliably synced too,
        // not something to special-case away).
        let inboxMailboxId = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "INBOX").fetchOne(db)?.id
            }
        )
        let seeded = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == inboxMailboxId).fetchAll(db)
        }
        #expect(seeded.count == 1)
        #expect(seeded.first?.flags.contains(.seen) == false)

        // What a second client would do concurrently: mark the existing
        // message \Seen, and deliver a brand new one.
        try DoveadmHelper.addFlag(user: user, flag: "\\Seen")
        try DoveadmHelper.save(user: user, content: Self.sampleMessage(uid: "int-new", subject: "integration new mail"))

        let progress = try await syncer.performIncrementalSync(auth: env.auth)
        #expect(progress.newMessages == 1)
        #expect(progress.didFullResync == false)

        let messages = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == inboxMailboxId).fetchAll(db)
        }
        #expect(messages.count == 2)
        #expect(messages.contains { $0.subject == "integration new mail" })

        let original = try #require(messages.first { $0.subject == "integration seed" })
        #expect(original.flags.contains(.seen))
    }

    /// Task #79 (実機バグ: Web でアーカイブ済みのメールが受信トレイに残り続ける):
    /// the exact real-device scenario, reproduced against a real IMAP
    /// server rather than `FakeIMAPSession` — another client (`doveadm`,
    /// standing in for e.g. Gmail's web UI) expunges one message out of
    /// INBOX between two `incrementalSync` passes, and the local copy must
    /// disappear. `MailboxSyncerTests`' `FakeIMAPSession`-driven suite
    /// already proves both the QRESYNC-direct and UID-SEARCH-fallback code
    /// paths in isolation; this proves the real wire protocol (whichever
    /// path this actual Dovecot build's advertised capabilities send
    /// `MailboxSyncer` down) actually removes the message end to end.
    @Test("incrementalSync removes a message another client (doveadm) expunged from INBOX — CONDSTORE path deletion detection")
    func incrementalSyncRemovesMessageExpungedByAnotherClient() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let user = "test1@otegami.test"

        defer { try? DoveadmHelper.restoreStandardFixtures() }

        // A known starting point: three messages, independent of whatever
        // `make mailstack-seed` last left in this INBOX.
        try DoveadmHelper.expungeAll(user: user)
        try DoveadmHelper.save(user: user, content: Self.sampleMessage(uid: "int-vanish-1", subject: "integration vanish survivor 1"))
        try DoveadmHelper.save(user: user, content: Self.sampleMessage(uid: "int-vanish-2", subject: "integration vanish target"))
        try DoveadmHelper.save(user: user, content: Self.sampleMessage(uid: "int-vanish-3", subject: "integration vanish survivor 3"))

        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Integration",
            email: user,
            authType: .password,
            imapHost: env.host,
            imapPort: env.port,
            imapSecurity: ConnectionSecurityRecord(env.imapConfig.security),
            imapAllowsInsecureTLS: env.imapConfig.allowsInsecureTLS,
            imapUsername: user
        )
        try await database.dbWriter.write { db in try account.insert(db) }

        let syncer = AccountSyncer(account: account, database: database) { config in
            MailCoreIMAPSession(config: config)
        }
        _ = try await syncer.performInitialSync(auth: env.auth)

        let inboxMailboxId = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == "INBOX").fetchOne(db)?.id
            }
        )
        let seeded = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == inboxMailboxId).fetchAll(db)
        }
        #expect(seeded.count == 3)

        // What a second client archiving/deleting a single message does:
        // an `EXPUNGE` that leaves the rest of the mailbox untouched.
        try DoveadmHelper.expungeMessage(user: user, subject: "integration vanish target")

        let progress = try await syncer.performIncrementalSync(auth: env.auth)
        #expect(progress.deletedMessages == 1)

        let messages = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == inboxMailboxId).fetchAll(db)
        }
        #expect(messages.count == 2)
        #expect(!messages.contains { $0.subject == "integration vanish target" })
        #expect(messages.contains { $0.subject == "integration vanish survivor 1" })
        #expect(messages.contains { $0.subject == "integration vanish survivor 3" })
    }

    @Test("performInitialSync threads the seeded References pair into one thread against a real IMAP server")
    func initialSyncThreadsSeededReferencesPair() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let user = "test1@otegami.test"

        // The standard fixtures (`make mailstack-seed`) include
        // 02-thread-original.eml / 03-thread-reply.eml, a References-linked
        // pair — restore them explicitly so this test doesn't depend on
        // whatever another test in this run left INBOX in.
        try DoveadmHelper.restoreStandardFixtures()

        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Integration",
            email: user,
            authType: .password,
            imapHost: env.host,
            imapPort: env.port,
            imapSecurity: ConnectionSecurityRecord(env.imapConfig.security),
            imapAllowsInsecureTLS: env.imapConfig.allowsInsecureTLS,
            imapUsername: user
        )
        try await database.dbWriter.write { db in try account.insert(db) }

        let syncer = AccountSyncer(account: account, database: database) { config in
            MailCoreIMAPSession(config: config)
        }
        _ = try await syncer.performInitialSync(auth: env.auth)

        let (threads, replyMessage) = try await database.dbWriter.read { db in
            (
                try ThreadRecord.filter(Column("accountId") == account.id).fetchAll(db),
                try MessageRecord.filter(Column("subject") == "Re: 明日の打ち合わせについて").fetchOne(db)
            )
        }
        let reply = try #require(replyMessage)
        let thread = try #require(threads.first { $0.id == reply.threadId })
        #expect(thread.messageCount == 2)
        #expect(thread.unreadCount >= 1)
    }

    @Test("a mailbox's sync failure is recorded against a real server SELECT failure and clears on the next successful sync")
    func mailboxSyncFailureRecordsAgainstRealServerAndClearsOnRecovery() async throws {
        // Partial-sync-failure visibility, exercised against the real dev
        // Dovecot rather than
        // `FakeIMAPSession` (`AccountSyncerTests` already covers the same
        // behavior against the fake — this is the "does MailCoreIMAPSession's
        // real SELECT-failure error actually get caught and recorded"
        // confirmation, the one thing the fake can't prove).
        //
        // Getting a mailbox that's *listed* but fails to *SELECT* against a
        // real server took some trial and error: simply `doveadm mailbox
        // delete`-ing a mailbox removes it from `LIST` entirely, so
        // `performIncrementalSync`'s `.mailbox(path:)` scope (which
        // re-`listMailboxes()`s and filters `targets` from that fresh list
        // every call) finds nothing to even attempt — no error, just a
        // silent no-op, since a target that isn't there isn't a target.
        // A `\Noselect` intermediate mailbox reproduces the real failure
        // mode instead: `doveadm mailbox create -u <user> "Parent/Child"`
        // without ever creating "Parent" itself makes Dovecot report
        // "Parent" as an implicit hierarchy placeholder — it *is* listed
        // (confirmed via `doveadm mailbox list`), but `SELECT`/`STATUS`
        // against it fails ("Mailbox doesn't exist") until `doveadm mailbox
        // create -u <user> Parent` turns it into a real, selectable
        // mailbox — exactly the create/still-there/now-selectable sequence
        // this test needs, and a real class of a mailbox that's visible in
        // a folder listing but not currently usable (the scenario this
        // feature exists for).
        let env = try #require(TestIMAPEnvironment.primary)
        let user = "test1@otegami.test"
        let parentPath = "IntegrationNoSelectParent"
        let childPath = "\(parentPath)/Child"

        try? DoveadmHelper.deleteMailbox(user: user, mailboxPath: childPath) // clean slate if a previous run left it
        try? DoveadmHelper.deleteMailbox(user: user, mailboxPath: parentPath)
        defer {
            try? DoveadmHelper.deleteMailbox(user: user, mailboxPath: childPath)
            try? DoveadmHelper.deleteMailbox(user: user, mailboxPath: parentPath)
        }
        // Creates `parentPath` as an implicit, \Noselect-only placeholder —
        // see the doc comment above.
        try DoveadmHelper.createMailbox(user: user, mailboxPath: childPath)
        #expect(try DoveadmHelper.listMailboxes(user: user).contains(parentPath))

        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Integration",
            email: user,
            authType: .password,
            imapHost: env.host,
            imapPort: env.port,
            imapSecurity: ConnectionSecurityRecord(env.imapConfig.security),
            imapAllowsInsecureTLS: env.imapConfig.allowsInsecureTLS,
            imapUsername: user
        )
        try await database.dbWriter.write { db in try account.insert(db) }

        let syncer = AccountSyncer(account: account, database: database) { config in
            MailCoreIMAPSession(config: config)
        }

        // Pass 1: performInitialSync discovers/upserts every mailbox
        // (including the \Noselect placeholder), but its per-mailbox sync
        // loop *skips* `\Noselect` entries entirely (`syncableInfos`'s
        // filter) — so the placeholder's row exists with no failure
        // recorded yet (never attempted), which is the correct starting
        // point for pass 2 below.
        _ = try await syncer.performInitialSync(auth: env.auth)

        let mailboxAfterInitialSync = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == parentPath).fetchOne(db)
            }
        )
        #expect(mailboxAfterInitialSync.lastSyncError == nil)

        // Pass 2: a scoped incremental sync explicitly targeting the
        // \Noselect placeholder (`.mailbox(path:)` doesn't filter out
        // `\Noselect` the way `.all`/`performInitialSync` do) must fail its
        // SELECT and record that failure without throwing out of
        // performIncrementalSync itself.
        _ = try await syncer.performIncrementalSync(auth: env.auth, scope: .mailbox(path: parentPath))

        let mailboxAfterFailure = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == parentPath).fetchOne(db)
            }
        )
        #expect(mailboxAfterFailure.lastSyncError != nil)
        #expect(mailboxAfterFailure.lastSyncErrorAt != nil)

        // Pass 3: turn the placeholder into a real, selectable mailbox — a
        // later successful sync of it must clear the recorded failure on
        // its own (the sidebar banner's "成功したら自動的に消える" requirement).
        try DoveadmHelper.createMailbox(user: user, mailboxPath: parentPath)
        _ = try await syncer.performIncrementalSync(auth: env.auth, scope: .mailbox(path: parentPath))

        let mailboxAfterRecovery = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == parentPath).fetchOne(db)
            }
        )
        #expect(mailboxAfterRecovery.lastSyncError == nil)
        #expect(mailboxAfterRecovery.lastSyncErrorAt == nil)
    }

    /// Task #44 (実機バグ: Gmail の「すべてのメール」を表示/pull-to-refresh
    /// しても直近の新着が反映されない): a non-INBOX-role mailbox, synced via
    /// exactly the `.mailbox(path:)` scope `MessageListView.refresh()`
    /// (pull-to-refresh) uses, must pick up new mail an external client
    /// delivers — the same shape `incrementalSyncPicksUpExternalChanges`
    /// already proves for INBOX (default `.inboxOnly` scope), but that test
    /// alone doesn't rule out a bug specific to non-INBOX targeting or
    /// real-CONDSTORE (`capabilities()` here reports whatever this actual
    /// Dovecot advertises, not a `FakeIMAPSession` script's say-so) — the
    /// two things `MailboxSyncerTests`'/`AccountSyncerTests`' `FakeIMAPSession`
    /// suites can't independently confirm against a real server. Uses a
    /// plain user-created mailbox (not `Archive`/`Sent`, which this dev
    /// mailstack auto-creates as `SPECIAL-USE` — see `DoveadmHelper
    /// .deleteMailbox`'s doc comment) so this test owns its entire
    /// lifecycle and can't collide with another opt-in test's fixtures.
    @Test("incrementalSync's .mailbox(path:) scope — pull-to-refresh on one specific non-INBOX mailbox — picks up new mail delivered by another client")
    func mailboxScopedIncrementalSyncPicksUpNewMailInNonInboxMailbox() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let user = "test1@otegami.test"
        let mailboxPath = "IntegrationAllMailSim"

        try? DoveadmHelper.deleteMailbox(user: user, mailboxPath: mailboxPath) // clean slate if a previous run left it
        defer { try? DoveadmHelper.deleteMailbox(user: user, mailboxPath: mailboxPath) }
        try DoveadmHelper.createMailbox(user: user, mailboxPath: mailboxPath)
        try DoveadmHelper.save(user: user, mailboxPath: mailboxPath, content: Self.sampleMessage(uid: "allmail-seed", subject: "AllMailSim seed"))

        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Integration",
            email: user,
            authType: .password,
            imapHost: env.host,
            imapPort: env.port,
            imapSecurity: ConnectionSecurityRecord(env.imapConfig.security),
            imapAllowsInsecureTLS: env.imapConfig.allowsInsecureTLS,
            imapUsername: user
        )
        try await database.dbWriter.write { db in try account.insert(db) }

        let syncer = AccountSyncer(account: account, database: database) { config in
            MailCoreIMAPSession(config: config)
        }
        // performInitialSync syncs every selectable mailbox, including this
        // one, via the uidValidity==0 windowed-resync path — the same path
        // a brand new mailbox always takes first.
        _ = try await syncer.performInitialSync(auth: env.auth)

        let mailboxId = try #require(
            try await database.dbWriter.read { db in
                try MailboxRecord.filter(Column("accountId") == account.id && Column("path") == mailboxPath).fetchOne(db)?.id
            }
        )
        let seeded = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == mailboxId).fetchAll(db)
        }
        #expect(seeded.count == 1)

        // What a second client (or, for real Gmail, the server itself
        // indexing a message into "すべてのメール" after it already landed
        // in INBOX) delivers in between.
        try DoveadmHelper.save(user: user, mailboxPath: mailboxPath, content: Self.sampleMessage(uid: "allmail-new", subject: "AllMailSim new mail"))

        // Exactly `MessageListView.refresh()`'s `.mailbox` case: scope the
        // incremental sync to this one mailbox's path.
        let progress = try await syncer.performIncrementalSync(auth: env.auth, scope: .mailbox(path: mailboxPath))
        #expect(progress.newMessages == 1)
        #expect(progress.didFullResync == false)

        let messages = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == mailboxId).fetchAll(db)
        }
        #expect(messages.count == 2)
        #expect(messages.contains { $0.subject == "AllMailSim new mail" })
    }

    private static func sampleMessage(uid: String, subject: String) -> String {
        "From: Aiko <aiko@otegami.test>\r\n" +
            "To: test1@otegami.test\r\n" +
            "Subject: \(subject)\r\n" +
            "Message-Id: <\(uid)@otegami.test>\r\n" +
            "Date: Mon, 1 Jan 2024 00:00:00 +0900\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "\r\n" +
            "Integration test body.\r\n"
    }
}
