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

        let seeded = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(seeded.count == 1)
        #expect(seeded.first?.flags.contains(.seen) == false)

        // What a second client would do concurrently: mark the existing
        // message \Seen, and deliver a brand new one.
        try DoveadmHelper.addFlag(user: user, flag: "\\Seen")
        try DoveadmHelper.save(user: user, content: Self.sampleMessage(uid: "int-new", subject: "integration new mail"))

        let progress = try await syncer.performIncrementalSync(auth: env.auth)
        #expect(progress.newMessages == 1)
        #expect(progress.didFullResync == false)

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
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
