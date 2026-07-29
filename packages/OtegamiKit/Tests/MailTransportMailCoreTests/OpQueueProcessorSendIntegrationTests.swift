import Foundation
import GRDB
import Testing
@testable import MailTransportMailCore
import MailTransport
import OtegamiCore
import OtegamiStore
import SyncEngine

/// Task #124 (二重送信防止): `OpQueueProcessorTests`' `overlappingReplayCallsSendExactlyOnce`
/// proves the fix against `FakeSMTPSession`, which only shows that this
/// process's own recorder saw one call — it can't show a real SMTP server
/// actually only *received* the message once. This suite exercises the
/// same "two overlapping `replay(account:auth:)` calls" scenario against
/// the dev mailstack's real Mailpit, verified via Mailpit's own REST API
/// (`MailpitClient.countMessages`, `SMTPIntegrationTests.swift`) — the
/// strongest evidence available in this repo that the reported "同じメール
/// が2通送信された" bug is actually fixed end to end, not just at the level
/// of this process's in-memory bookkeeping.
///
/// Opt-in like the rest of this target: skipped unless
/// `OTEGAMI_TEST_IMAP_HOST` is set. Run with:
///
/// ```sh
/// make mailstack-up
/// OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter OpQueueProcessorSendIntegrationTests
/// make mailstack-down
/// ```
@Suite(
    "OpQueueProcessor.send against dev mailstack (real Dovecot + Mailpit)",
    .enabled(if: TestIMAPEnvironment.primary != nil, "set OTEGAMI_TEST_IMAP_HOST to run")
)
struct OpQueueProcessorSendIntegrationTests {
    private let fakeMessageBuilder: @Sendable (ComposeDraft) -> BuiltMessage = { draft in
        MailCoreMessageBuilder.build(draft)
    }

    @Test("two overlapping replay() calls against a real SMTP server (Mailpit) deliver the message exactly once")
    func overlappingReplayCallsDeliverExactlyOnceToRealSMTP() async throws {
        let env = try #require(TestIMAPEnvironment.primary)

        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Integration",
            email: env.username,
            authType: .password,
            imapHost: env.host,
            imapPort: env.port,
            imapSecurity: ConnectionSecurityRecord(env.imapConfig.security),
            imapAllowsInsecureTLS: env.imapConfig.allowsInsecureTLS,
            imapUsername: env.username,
            smtpHost: env.host,
            smtpPort: 1025,
            smtpSecurity: .plain,
            smtpUsername: ""
        )
        try await database.dbWriter.write { db in try account.insert(db) }

        let uniqueMarker = UUID().uuidString.prefix(8)
        let subject = "otegami Task #124 二重送信防止統合テスト \(uniqueMarker)"
        let outboxId: Int64 = try await database.dbWriter.write { db in
            var outbox = OutboxMessageRecord(
                accountId: account.id,
                toAddresses: [EmailAddress(address: "recipient@otegami.test")],
                subject: subject,
                plainTextBody: "Task #124 の二重送信防止を実 SMTP (Mailpit) に対して検証する統合テストです。"
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

        // The actual reported bug's mechanism: two independent triggers
        // (a swipe action, foreground sync, the IDLE loop,
        // `PendingSendCoordinator`'s countdown finalize, ...) both calling
        // `replayOpQueue` for the same account while a `.send` op is still
        // pending. `inFlightAccountIds` (in-process) makes the second call
        // here a fast no-op; this asserts the *outcome* that matters —
        // Mailpit received the message exactly once — not just that only
        // one local `ReplayResult.succeeded` came back.
        async let first = processor.replay(account: account, auth: env.auth)
        async let second = processor.replay(account: account, auth: env.auth)
        _ = try await (first, second)

        let found = try await MailpitClient.pollForMessage(withSubjectContaining: String(uniqueMarker), timeout: 15)
        #expect(found != nil, "expected the message to actually reach Mailpit")

        // Give a genuine duplicate delivery time to show up before counting
        // — `pollForMessage` above only proves *a* message arrived, not
        // that a second one isn't still in flight from a race this fix
        // failed to close.
        try await Task.sleep(for: .seconds(3))
        let deliveredCount = try await MailpitClient.countMessages(withSubjectContaining: String(uniqueMarker))
        #expect(deliveredCount == 1, "the message must be delivered to Mailpit exactly once, not \(deliveredCount) times")

        let remainingOutbox = try await database.dbWriter.read { db in try OutboxMessageRecord.fetchOne(db, key: outboxId) }
        #expect(remainingOutbox == nil, "the outbox row should be deleted once the send succeeds")
    }
}
