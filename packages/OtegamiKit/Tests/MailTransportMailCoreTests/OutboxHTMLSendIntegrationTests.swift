import Foundation
import GRDB
import Testing
@testable import MailTransportMailCore
import MailTransport
import OtegamiCore
import OtegamiStore
import SyncEngine

/// Task #156 (作成画面リッチテキスト化のHTML送信配線): `MessageBuilderTests
/// .htmlBodyProducesMultipartAlternative` already proves `MailCoreMessageBuilder`
/// itself builds a correct `multipart/alternative` message when handed a
/// `ComposeDraft.htmlBody` — what that unit test *can't* show is that a
/// formatted `OutboxMessageRecord` (the row `ComposerView.send()` actually
/// writes) makes it all the way through `OpQueueProcessor`'s `.send` replay
/// and out over real SMTP with the same structure intact. This suite closes
/// that gap against the dev mailstack's real Mailpit, the same "verify via
/// Mailpit's own REST API" approach `OpQueueProcessorSendIntegrationTests`
/// (Task #124) uses.
///
/// Opt-in like the rest of this target: skipped unless
/// `OTEGAMI_TEST_IMAP_HOST` is set. Run with:
///
/// ```sh
/// make mailstack-up
/// OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter OutboxHTMLSendIntegrationTests
/// make mailstack-down
/// ```
@Suite(
    "OutboxMessageRecord.htmlBody against dev mailstack (real Dovecot + Mailpit)",
    .enabled(if: TestIMAPEnvironment.primary != nil, "set OTEGAMI_TEST_IMAP_HOST to run")
)
struct OutboxHTMLSendIntegrationTests {
    private let fakeMessageBuilder: @Sendable (ComposeDraft) -> BuiltMessage = { draft in
        MailCoreMessageBuilder.build(draft)
    }

    @Test("a formatted OutboxMessageRecord sends as multipart/alternative with the HTML part carrying its formatting tags")
    func formattedOutboxSendsAsMultipartAlternative() async throws {
        let env = try #require(TestIMAPEnvironment.primary)

        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Integration", email: env.username, authType: .password,
            imapHost: env.host, imapPort: env.port,
            imapSecurity: ConnectionSecurityRecord(env.imapConfig.security),
            imapAllowsInsecureTLS: env.imapConfig.allowsInsecureTLS,
            imapUsername: env.username,
            smtpHost: env.host, smtpPort: 1025, smtpSecurity: .plain, smtpUsername: ""
        )
        try await database.dbWriter.write { db in try account.insert(db) }

        let uniqueMarker = UUID().uuidString.prefix(8)
        let subject = "otegami Task #156 HTML送信配線統合テスト \(uniqueMarker)"
        // Same HTML shape `RichTextHTMLCoder.encode(_:)` actually emits for a
        // one-paragraph bold run (`RichTextHTMLCoderTests`'s own fixtures) —
        // not hand-rolled arbitrary HTML, so this test exercises the real
        // send-path shape end to end.
        let htmlBody = "<p><b>formatted</b> body</p>"
        let outboxId: Int64 = try await database.dbWriter.write { db in
            var outbox = OutboxMessageRecord(
                accountId: account.id,
                toAddresses: [EmailAddress(address: "recipient@otegami.test")],
                subject: subject,
                plainTextBody: "formatted body",
                htmlBody: htmlBody
            )
            try outbox.insert(db)
            let outboxId = try #require(outbox.id)
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outboxId, db: db)
            return outboxId
        }

        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in MailCoreIMAPSession(config: config) },
            smtpSessionFactory: { config in MailCoreSMTPSession(config: config) },
            messageBuilder: fakeMessageBuilder
        )
        _ = try await processor.replay(account: account, auth: env.auth)

        let found = try await MailpitClient.pollForMessage(withSubjectContaining: String(uniqueMarker), timeout: 15)
        let message = try #require(found, "expected the formatted message to actually reach Mailpit")

        let raw = try await MailpitClient.fetchRawSource(id: message.id)
        #expect(raw.contains("multipart/alternative"), "a message with htmlBody set must send as multipart/alternative, not plain text/plain")
        #expect(raw.contains("text/html"), "expected a text/html part alongside the text/plain fallback")

        // Mailpit's own decoded view (`Text`/`HTML`) rather than searching
        // `raw` for the literal tag — MailCore2's chosen transfer encoding
        // for the HTML part isn't this test's concern, only that the actual
        // formatting survived the whole send pipeline intact.
        let detail = try await MailpitClient.fetchMessageDetail(id: message.id)
        #expect(detail.text.contains("formatted body"), "expected the text/plain fallback part to still carry the plain-text projection")
        #expect(detail.html.localizedCaseInsensitiveContains("<b>"), "expected the HTML part to carry the bold tag RichTextHTMLCoder.encode(_:) emitted")
        #expect(detail.html.contains("formatted"), "expected the HTML part's text content to survive")

        let remainingOutbox = try await database.dbWriter.read { db in try OutboxMessageRecord.fetchOne(db, key: outboxId) }
        #expect(remainingOutbox == nil, "the outbox row should be deleted once the send succeeds")
    }

    /// Task #162 (実機フィードバック「署名が本文に混ざって編集しづらい」):
    /// `ComposerView.send()` itself lives in the app target and can't be
    /// called from here, so this simulates exactly what it does — combine
    /// the body with a signature via `RichTextDocument.appendingSignature(_:)`
    /// (the one place body/signature ever combine) and hand the resulting
    /// plain/HTML pair to `OutboxMessageRecord`, same as the plain-bold test
    /// above simulates `RichTextHTMLCoder.encode(_:)`'s own output — proving
    /// the combined body survives the real send pipeline with its "本文 +
    /// 空行 + 署名" structure intact, not just that the pure combining logic
    /// itself is correct (`RichTextHTMLCoderTests`'s unit tests already
    /// cover that in isolation).
    @Test("a body combined with a signature sends with exactly one blank line separating them, in both the plain and HTML parts")
    func bodyCombinedWithSignatureSendsWithABlankLineSeparator() async throws {
        let env = try #require(TestIMAPEnvironment.primary)

        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Integration", email: env.username, authType: .password,
            imapHost: env.host, imapPort: env.port,
            imapSecurity: ConnectionSecurityRecord(env.imapConfig.security),
            imapAllowsInsecureTLS: env.imapConfig.allowsInsecureTLS,
            imapUsername: env.username,
            smtpHost: env.host, smtpPort: 1025, smtpSecurity: .plain, smtpUsername: ""
        )
        try await database.dbWriter.write { db in try account.insert(db) }

        let uniqueMarker = UUID().uuidString.prefix(8)
        let subject = "otegami Task #162 署名結合送信統合テスト \(uniqueMarker)"
        let combinedDocument = RichTextDocument.plainText("本文です \(uniqueMarker)")
            .appendingSignature("よろしくお願いします。\n山田太郎")
        let plainTextBody = combinedDocument.plainText
        let htmlBody = RichTextHTMLCoder.encode(combinedDocument)

        let outboxId: Int64 = try await database.dbWriter.write { db in
            var outbox = OutboxMessageRecord(
                accountId: account.id,
                toAddresses: [EmailAddress(address: "recipient@otegami.test")],
                subject: subject,
                plainTextBody: plainTextBody,
                htmlBody: htmlBody
            )
            try outbox.insert(db)
            let outboxId = try #require(outbox.id)
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outboxId, db: db)
            return outboxId
        }

        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in MailCoreIMAPSession(config: config) },
            smtpSessionFactory: { config in MailCoreSMTPSession(config: config) },
            messageBuilder: fakeMessageBuilder
        )
        _ = try await processor.replay(account: account, auth: env.auth)

        let found = try await MailpitClient.pollForMessage(withSubjectContaining: String(uniqueMarker), timeout: 15)
        let message = try #require(found, "expected the signature-combined message to actually reach Mailpit")

        let detail = try await MailpitClient.fetchMessageDetail(id: message.id)
        // Line-based, not an exact multi-line substring match — the raw
        // transport can carry CRLF line endings, and Swift treats "\r\n" as
        // one indivisible grapheme cluster, so a plain "\n"-based expected
        // string can fail a `.contains(_:)` check even when the visible
        // line structure is exactly right.
        let normalizedText = detail.text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedText.components(separatedBy: "\n")
        let bodyLineIndex = try #require(lines.firstIndex(where: { $0.contains(uniqueMarker) }))
        let greetingLineIndex = try #require(lines.firstIndex(where: { $0.contains("よろしくお願いします。") }))
        #expect(greetingLineIndex == bodyLineIndex + 2, "expected exactly one blank line between the body and the signature greeting")
        if greetingLineIndex > bodyLineIndex + 1 {
            #expect(
                lines[(bodyLineIndex + 1)..<greetingLineIndex].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                "expected only a blank line between the body and the signature, no leftover body/signature text"
            )
        }
        #expect(detail.html.contains("よろしくお願いします。"), "expected the signature text to survive in the HTML part")
        #expect(detail.html.contains("<p><br></p>"), "expected RichTextHTMLCoder's own blank-line-paragraph encoding to survive as the separator between body and signature")
        if let bodyRange = detail.html.range(of: uniqueMarker), let signatureRange = detail.html.range(of: "よろしくお願いします。") {
            #expect(bodyRange.upperBound < signatureRange.lowerBound, "expected the body to precede the signature in the HTML part")
        }

        let remainingOutbox = try await database.dbWriter.read { db in try OutboxMessageRecord.fetchOne(db, key: outboxId) }
        #expect(remainingOutbox == nil, "the outbox row should be deleted once the send succeeds")
    }
}
