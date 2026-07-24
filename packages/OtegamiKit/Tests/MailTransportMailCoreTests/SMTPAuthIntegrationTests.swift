import Foundation
import Testing
@testable import MailTransportMailCore
import MailTransport
import OtegamiCore

/// Integration tests against the dev mailstack's second, AUTH-*required*
/// Mailpit instance (`mailpit-auth` in `dev/mailstack/compose.yml`, port
/// 1026 — see `dev/mailstack/mailpit-auth/users.txt` for the test
/// credential). `SMTPIntegrationTests` above only ever exercises the
/// default `mailpit` service, which requires no auth at all — exactly the
/// kind of server `MailCoreSMTPSession.connect`'s AUTH-not-supported
/// fallback exists for. This suite instead confirms the *other* half of
/// that change's safety requirement: a server that genuinely does support
/// (and require) AUTH must keep behaving exactly as before —
/// correct credentials still succeed, and incorrect/missing credentials
/// still fail clearly, never silently falling back to no-auth.
///
/// Opt-in, gated the same way as `SMTPIntegrationTests`: skipped unless
/// `OTEGAMI_TEST_IMAP_HOST` is set. To run:
///
/// ```sh
/// make mailstack-up
/// OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter SMTPAuthIntegrationTests
/// make mailstack-down
/// ```
@Suite(
    "MailCoreSMTPSession against dev mailstack's AUTH-required Mailpit",
    .enabled(if: TestIMAPEnvironment.primary != nil, "set OTEGAMI_TEST_IMAP_HOST to run")
)
struct SMTPAuthIntegrationTests {
    /// `dev/mailstack/mailpit-auth/users.txt`'s only credential.
    private static let correctAuth = MailAuth.password(username: "smtpauth", password: "smtpauth1234")

    private static func config(host: String) -> SMTPConfig {
        SMTPConfig(host: host, port: 1026, security: .plain)
    }

    @Test("correct credentials against an AUTH-required server connect and send successfully")
    func correctCredentialsSucceed() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let session = MailCoreSMTPSession(config: Self.config(host: env.host))
        try await session.connect(auth: Self.correctAuth)
        defer { Task { await session.disconnect() } }

        let uniqueMarker = UUID().uuidString.prefix(8)
        let subject = "otegami SMTP AUTH 統合テスト (正しい資格情報) \(uniqueMarker)"
        let draft = ComposeDraft(
            from: EmailAddress(address: "test1@otegami.test"),
            to: [EmailAddress(address: "recipient@otegami.test")],
            subject: subject,
            plainTextBody: "AUTH 必須サーバーへの正しい資格情報での送信テストです。"
        )
        let built = MailCoreMessageBuilder.build(draft)
        try await session.sendMessage(messageData: built.data, from: draft.from, recipients: draft.to)

        let found = try await MailpitClient.pollForMessage(
            withSubjectContaining: String(uniqueMarker), port: 8026, timeout: 15
        )
        #expect(found?.subject == subject)
    }

    @Test("a wrong password against an AUTH-required server fails clearly at connect() — never falls back to no-auth")
    func wrongPasswordFailsAtConnect() async throws {
        let session = MailCoreSMTPSession(config: Self.config(host: try #require(TestIMAPEnvironment.primary).host))
        let wrongAuth = MailAuth.password(username: "smtpauth", password: "not-the-right-password")

        await #expect(throws: MailTransportError.self) {
            try await session.connect(auth: wrongAuth)
        }
    }

    @Test("a blank username against an AUTH-required server connects (login-only round trip skips AUTH) but fails clearly on send")
    func blankUsernameConnectsButFailsToSend() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let session = MailCoreSMTPSession(config: Self.config(host: env.host))
        let blankAuth = MailAuth.password(username: "", password: "")

        // `connect(auth:)` only performs a plain EHLO/AUTH round trip
        // (`loginOperation()`, see its doc comment) and never touches
        // MAIL/RCPT — a blank username skips AUTH entirely up front
        // (`apply(_:to:)`), so this succeeds even though the server will
        // go on to reject anything requiring authentication. This isn't
        // this change's fallback kicking in (that only triggers on a
        // *non-blank* username whose AUTH attempt was rejected as
        // unsupported) — it's the same pre-existing blank-username
        // behavior `SMTPIntegrationTests` already documents against the
        // no-auth `mailpit` service, confirmed here to behave identically
        // against a server that actually does require auth.
        try await session.connect(auth: blankAuth)
        defer { Task { await session.disconnect() } }

        let draft = ComposeDraft(
            from: EmailAddress(address: "test1@otegami.test"),
            to: [EmailAddress(address: "recipient@otegami.test")],
            subject: "should never be delivered",
            plainTextBody: "この送信は認証必須サーバーに拒否されるはずです。"
        )
        let built = MailCoreMessageBuilder.build(draft)

        await #expect(throws: MailTransportError.self) {
            try await session.sendMessage(messageData: built.data, from: draft.from, recipients: draft.to)
        }
    }
}

private extension MailpitClient {
    /// `MailpitClient.pollForMessage(withSubjectContaining:timeout:)` above
    /// (in `SMTPIntegrationTests.swift`) is hardcoded to the default
    /// `mailpit` service's port 8025 — this overload lets
    /// `SMTPAuthIntegrationTests` poll the second, AUTH-required
    /// instance's REST API (port 8026) instead, without duplicating the
    /// polling loop.
    static func pollForMessage(withSubjectContaining marker: String, port: Int, timeout: TimeInterval) async throws -> MessageSummary? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let url = URL(string: "http://localhost:\(port)/api/v1/messages?limit=50")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let messages = try JSONDecoder().decode(MessagesResponse.self, from: data).messages
            if let match = messages.first(where: { $0.subject.contains(marker) }) {
                return match
            }
            try await Task.sleep(for: .seconds(1))
        }
        return nil
    }
}
