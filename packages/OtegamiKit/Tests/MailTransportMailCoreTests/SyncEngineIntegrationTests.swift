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
        // docs/qa-findings.md's partial-sync-failure visibility follow-up,
        // exercised against the real dev Dovecot rather than
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
