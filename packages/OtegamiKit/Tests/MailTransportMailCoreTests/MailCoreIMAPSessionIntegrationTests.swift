import Foundation
import Testing
@testable import MailTransportMailCore
import MailTransport

/// Integration tests against a real IMAP server — the dev mailstack's
/// Dovecot (`dev/mailstack`) by default, seeded via `make mailstack-seed`
/// (see `dev/mailstack/seed/fixtures/*.eml`).
///
/// Opt-in: skipped (not failed) unless `OTEGAMI_TEST_IMAP_HOST` is set, so a
/// plain `swift test` never requires a running mail server. To run:
///
/// ```sh
/// make mailstack-up
/// make mailstack-seed
/// OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter MailCoreIMAPSessionIntegrationTests
/// make mailstack-down
/// ```
///
/// All connection details are overridable via environment variables so the
/// same suite can point at IMAPS (port 1993, self-signed cert) or a
/// non-default host/port; see `TestIMAPEnvironment` for the full list.
@Suite(
    "MailCoreIMAPSession against dev mailstack",
    .enabled(if: TestIMAPEnvironment.primary != nil, "set OTEGAMI_TEST_IMAP_HOST to run")
)
struct MailCoreIMAPSessionIntegrationTests {
    @Test("lists INBOX, selects it, and fetches test1's seeded envelopes")
    func test1InboxEnvelopes() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        let mailboxes = try await session.listMailboxes()
        #expect(mailboxes.contains { $0.path.caseInsensitiveCompare("INBOX") == .orderedSame })

        let status = try await session.select("INBOX")
        // `>=` rather than `==`: `make mailstack-seed` is not idempotent
        // (each run re-`doveadm save`s the fixtures), so a mailstack that's
        // been seeded more than once legitimately has extra copies. The
        // fixed set of seed subjects/headers below is what this test
        // actually cares about.
        #expect(status.messageCount >= 4)

        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .all, batchSize: 50)
        #expect(envelopes.count >= 4)

        let subjects = Set(envelopes.compactMap(\.subject))
        #expect(subjects.contains("ようこそ otegami へ"))
        #expect(subjects.contains("明日の打ち合わせについて"))
        #expect(subjects.contains("Re: 明日の打ち合わせについて"))
        #expect(subjects.contains("Ｆｗｄ：今月のリリースノート"))

        let reply = try #require(envelopes.first { $0.subject == "Re: 明日の打ち合わせについて" })
        #expect(reply.inReplyTo == "<seed-0002@otegami.test>")
        #expect(reply.references == ["<seed-0002@otegami.test>"])
        #expect(reply.messageId == "<seed-0003@otegami.test>")

        let original = try #require(envelopes.first { $0.subject == "明日の打ち合わせについて" })
        #expect(original.messageId == "<seed-0002@otegami.test>")
        #expect(original.from.first?.address == "aiko@otegami.test")
    }

    @Test("fetches test2's seeded envelope")
    func test2InboxEnvelopes() async throws {
        let env = try #require(TestIMAPEnvironment.secondary)
        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        _ = try await session.select("INBOX")
        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .all, batchSize: 50)

        #expect(envelopes.count >= 1)
        let welcome = try #require(envelopes.first { $0.messageId == "<seed-0005@otegami.test>" })
        #expect(welcome.subject == "test2 アカウントへようこそ")
    }

    @Test("reports server capabilities without throwing")
    func capabilities() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        // Not asserting a specific capability set: Dovecot's advertised
        // capabilities are an implementation detail this test shouldn't be
        // coupled to. Successfully bridging MCOIndexSet → Set<IMAPCapability>
        // without throwing is what's under test.
        _ = try await session.capabilities()
    }
}

/// Connection details for the dev mailstack (or another IMAP server),
/// sourced from environment variables so CI/local runs can opt in without
/// code changes. Defaults match `dev/mailstack`'s seeded accounts
/// (`docs/dev-mailstack.md`).
struct TestIMAPEnvironment {
    var host: String
    var port: Int
    var security: MailConnectionSecurity
    var allowsInsecureTLS: Bool
    var username: String
    var password: String

    var imapConfig: IMAPConfig {
        IMAPConfig(host: host, port: port, security: security, allowsInsecureTLS: allowsInsecureTLS)
    }

    var auth: MailAuth {
        .password(username: username, password: password)
    }

    private static let environment = ProcessInfo.processInfo.environment

    /// `nil` (suite skipped) unless `OTEGAMI_TEST_IMAP_HOST` is set.
    static var primary: TestIMAPEnvironment? {
        make(userKey: "OTEGAMI_TEST_IMAP_USER", userDefault: "test1@otegami.test",
             passwordKey: "OTEGAMI_TEST_IMAP_PASSWORD", passwordDefault: "test1234")
    }

    /// The dev mailstack's second seeded account, for multi-account
    /// coverage. Also `nil` unless `OTEGAMI_TEST_IMAP_HOST` is set.
    static var secondary: TestIMAPEnvironment? {
        make(userKey: "OTEGAMI_TEST_IMAP_USER2", userDefault: "test2@otegami.test",
             passwordKey: "OTEGAMI_TEST_IMAP_PASSWORD2", passwordDefault: "test1234")
    }

    private static func make(
        userKey: String, userDefault: String,
        passwordKey: String, passwordDefault: String
    ) -> TestIMAPEnvironment? {
        guard let host = environment["OTEGAMI_TEST_IMAP_HOST"] else { return nil }

        let useTLS = environment["OTEGAMI_TEST_IMAP_TLS"].map { $0 == "1" || $0.lowercased() == "true" } ?? false
        let defaultPort = useTLS ? 1993 : 1143
        let port = environment["OTEGAMI_TEST_IMAP_PORT"].flatMap(Int.init) ?? defaultPort

        return TestIMAPEnvironment(
            host: host,
            port: port,
            // The dev mailstack's IMAPS listener uses a self-signed
            // certificate; only relax certificate checking for it, never
            // silently for a real account.
            security: useTLS ? .tls : .plain,
            allowsInsecureTLS: useTLS,
            username: environment[userKey] ?? userDefault,
            password: environment[passwordKey] ?? passwordDefault
        )
    }
}
