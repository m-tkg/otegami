import Foundation
import Testing
@testable import MailTransportMailCore
import MailTransport
import OtegamiCore

/// Integration tests against the dev mailstack's real Mailpit (SMTP) +
/// Dovecot (IMAP) — M5's send path end to end, not just the local
/// RFC 822-building unit coverage in `MessageBuilderTests`.
///
/// Opt-in, gated the same way as `MailCoreIMAPSessionIntegrationTests`:
/// skipped unless `OTEGAMI_TEST_IMAP_HOST` is set. To run:
///
/// ```sh
/// make mailstack-up
/// OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter SMTPIntegrationTests
/// make mailstack-down
/// ```
@Suite(
    "MailCoreSMTPSession against dev mailstack (Mailpit)",
    .enabled(if: TestIMAPEnvironment.primary != nil, "set OTEGAMI_TEST_IMAP_HOST to run")
)
struct SMTPIntegrationTests {
    /// Mailpit (`dev/mailstack/compose.yml`) runs with no auth configured
    /// and rejects an `AUTH` attempt outright — `MCOSMTPSession` only
    /// issues one when `username` is non-empty, so an empty-credentials
    /// `MailAuth` skips straight to a plain `EHLO`, matching how a real
    /// unauthenticated relay is used. Not representative of a real
    /// account's SMTP credentials (those do get authenticated — see
    /// `MailCoreSMTPSession.connect`'s doc comment); this is specific to
    /// exercising the dev mailstack.
    private static let mailpitAuth = MailAuth.password(username: "", password: "")

    /// UX-bug regression (a real user hit this against this exact server):
    /// a *non-blank* SMTP username used to always trigger a real `AUTH`
    /// attempt, which the dev mailstack's no-auth `mailpit` rejects
    /// outright (`502 5.5.1 Command not implemented`) — failing the
    /// connection test/send even though this server works fine
    /// unauthenticated. `MailCoreSMTPSession.connect`'s AUTH-not-supported
    /// fallback (see its doc comment) now retries without auth on exactly
    /// that rejection, so this must now succeed instead of throwing —
    /// unlike `mailpitAuth` above (blank username), this exercises the new
    /// fallback path itself, not the pre-existing blank-username skip.
    @Test("a non-blank SMTP username against Mailpit (no AUTH support) still connects, via the AUTH-not-supported fallback")
    func nonBlankUsernameAgainstNoAuthServerStillConnects() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let smtpConfig = SMTPConfig(host: env.host, port: 1025, security: .plain)
        let session = MailCoreSMTPSession(config: smtpConfig)
        // A real-looking username/password, deliberately not blank —
        // Mailpit has no concept of a matching credential, so any
        // rejection it produces has to come from "I don't do AUTH at
        // all", not "these credentials are wrong".
        try await session.connect(auth: .password(username: "test1@otegami.test", password: "test1234"))
        defer { Task { await session.disconnect() } }

        let uniqueMarker = UUID().uuidString.prefix(8)
        let subject = "otegami SMTP AUTH フォールバック統合テスト \(uniqueMarker)"
        let draft = ComposeDraft(
            from: EmailAddress(address: "test1@otegami.test"),
            to: [EmailAddress(address: "recipient@otegami.test")],
            subject: subject,
            plainTextBody: "AUTH 非対応サーバーへの、ユーザー名入りでの送信フォールバックテストです。"
        )
        let built = MailCoreMessageBuilder.build(draft)
        try await session.sendMessage(messageData: built.data, from: draft.from, recipients: draft.to)

        let found = try await MailpitClient.pollForMessage(withSubjectContaining: String(uniqueMarker), timeout: 15)
        #expect(found?.subject == subject)
    }

    @Test("sends a Japanese-subject message via Mailpit SMTP, visible over Mailpit's REST API")
    func sendsMessageVisibleInMailpit() async throws {
        let env = try #require(TestIMAPEnvironment.primary)

        // Mailpit doesn't require authentication by default (dev/mailstack's
        // compose.yml runs it with no auth env vars set) — the dev mailstack
        // account's own IMAP credentials are reused here anyway since
        // `MailAuth` requires *something*, and MailCoreSMTPSession's
        // `connect` (an EHLO/AUTH round trip) succeeds regardless of what
        // Mailpit does with the credentials.
        let smtpConfig = SMTPConfig(host: env.host, port: 1025, security: .plain)
        let session = MailCoreSMTPSession(config: smtpConfig)
        try await session.connect(auth: Self.mailpitAuth)
        defer { Task { await session.disconnect() } }

        let uniqueMarker = UUID().uuidString.prefix(8)
        let subject = "otegami M5 統合テスト \(uniqueMarker)"
        let draft = ComposeDraft(
            from: EmailAddress(name: "Otegami Test", address: "test1@otegami.test"),
            to: [EmailAddress(address: "recipient@otegami.test")],
            subject: subject,
            plainTextBody: "これは M5 の SMTP 統合テスト送信です。"
        )
        let built = MailCoreMessageBuilder.build(draft)

        try await session.sendMessage(
            messageData: built.data,
            from: draft.from,
            recipients: draft.to
        )

        let found = try await MailpitClient.pollForMessage(withSubjectContaining: String(uniqueMarker), timeout: 15)
        #expect(found?.subject == subject)
    }

    @Test("a message SMTP-sent to Mailpit can also be APPENDed to Dovecot's Sent mailbox and found via doveadm")
    func sentMessageAppearsInDovecotSentViaAppend() async throws {
        let env = try #require(TestIMAPEnvironment.primary)

        // This test leaves a message behind in Dovecot's Sent mailbox —
        // clean it up so `MailCoreIMAPSessionIntegrationTests`/
        // `SyncEngineIntegrationTests` (which sync *every* mailbox, not
        // just INBOX, and assert exact whole-account message counts)
        // aren't affected by run order within the same `swift test`
        // invocation, the same concern `SyncEngineIntegrationTests`'s own
        // `restoreStandardFixtures()` defer documents for INBOX.
        defer { try? DoveadmHelper.expungeAll(user: env.username, mailboxPath: "Sent") }

        let uniqueMarker = UUID().uuidString.prefix(8)
        let subject = "otegami M5 Sent APPEND テスト \(uniqueMarker)"
        let draft = ComposeDraft(
            from: EmailAddress(address: "test1@otegami.test"),
            to: [EmailAddress(address: "recipient@otegami.test")],
            subject: subject,
            plainTextBody: "Sent APPEND のテストです。"
        )
        let built = MailCoreMessageBuilder.build(draft)

        // SMTP send (Mailpit) — mirrors what OpQueueProcessor.send does
        // before the best-effort Sent APPEND.
        let smtpSession = MailCoreSMTPSession(config: SMTPConfig(host: env.host, port: 1025, security: .plain))
        try await smtpSession.connect(auth: Self.mailpitAuth)
        try await smtpSession.sendMessage(messageData: built.data, from: draft.from, recipients: draft.to)
        await smtpSession.disconnect()

        // IMAP APPEND to Dovecot's Sent mailbox (dev/mailstack's Dovecot
        // auto-advertises SPECIAL-USE Sent/Trash/Drafts/Junk — see M3's
        // verify notes — so "Sent" is a valid, pre-existing mailbox path).
        let imapSession = MailCoreIMAPSession(config: env.imapConfig)
        try await imapSession.connect(auth: env.auth)
        defer { Task { await imapSession.disconnect() } }
        _ = try await imapSession.append(mailboxPath: "Sent", messageData: built.data, flags: .seen)

        // Confirm server-side via doveadm rather than re-fetching over the
        // same session — proves the APPEND round-tripped through Dovecot's
        // own storage, not just this process's in-memory state.
        var found = false
        for _ in 0..<10 {
            let output = DoveadmHelper.fetchFlagsBySubject(user: env.username, mailboxPath: "Sent", subject: subject)
            if !output.isEmpty {
                found = true
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        #expect(found, "Expected doveadm to find the APPENDed message in Sent by its unique subject")
    }
}

/// Minimal client for Mailpit's REST API (`GET /api/v1/messages`,
/// `docs: https://mailpit.axllent.org/docs/api-v1/`) — just enough to poll
/// for a just-sent message by subject substring, no full API surface.
enum MailpitClient {
    struct MessageSummary: Decodable {
        var subject: String

        enum CodingKeys: String, CodingKey {
            case subject = "Subject"
        }
    }

    struct MessagesResponse: Decodable {
        var messages: [MessageSummary]
    }

    /// Polls `GET http://localhost:8025/api/v1/messages` (Mailpit's default
    /// dev/mailstack port, `compose.yml`) every second until a message
    /// whose subject contains `marker` shows up, or `timeout` elapses.
    static func pollForMessage(withSubjectContaining marker: String, timeout: TimeInterval) async throws -> MessageSummary? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = try await fetchMessages().first(where: { $0.subject.contains(marker) }) {
                return match
            }
            try await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    private static func fetchMessages() async throws -> [MessageSummary] {
        let url = URL(string: "http://localhost:8025/api/v1/messages?limit=50")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(MessagesResponse.self, from: data).messages
    }
}
