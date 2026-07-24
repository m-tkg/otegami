import Foundation
import GRDB
import Testing
@testable import MailTransportMailCore
import MailTransport
import OtegamiStore
import SyncEngine

/// M8 integration coverage: `SyncEngine.AttachmentFetcher` end-to-end
/// against the real dev mailstack Dovecot — `MailCoreIMAPSessionIntegrationTests`
/// already covers the transport layer (`MailCoreIMAPSession.fetchMessageBody`
/// returning correct bytes); this suite instead drives the actual
/// `SyncEngine` types an app build uses (`BodyFetcher` to discover the
/// attachment row the way a real sync would, then `AttachmentFetcher` to
/// download it), confirming the two compose correctly end-to-end and that
/// the downloaded bytes land on disk byte-for-byte.
///
/// Read-only against the standing seed fixtures (no `doveadm expunge`/
/// `save`), so — unlike `SyncEngineIntegrationTests` — this doesn't need to
/// restore fixtures afterward or run `.serialized`.
///
/// Opt-in like the rest of this target. Run with:
///
/// ```sh
/// make mailstack-up
/// make mailstack-seed
/// OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter AttachmentFetcherIntegrationTests
/// make mailstack-down
/// ```
@Suite(
    "AttachmentFetcher against dev mailstack",
    .enabled(if: TestIMAPEnvironment.primary != nil, "set OTEGAMI_TEST_IMAP_HOST to run")
)
struct AttachmentFetcherIntegrationTests {
    private static let expectedPNGBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAIAAABvFaqvAAAAH0lEQVR42mN4USVHFcQwatCoQaMGjRo0atCoQQNvEAD6qmAurCoQRgAAAABJRU5ErkJggg==")!

    /// Deletes whatever `AttachmentFetcher.fetchAndStore` wrote for
    /// `accountId`, so a repeated test run doesn't accumulate files under
    /// the real (not in-memory) Application Support directory.
    private func cleanUp(accountId: String) {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        try? FileManager.default.removeItem(at: base.appendingPathComponent("otegami/Attachments/\(accountId)", isDirectory: true))
    }

    @Test("BodyFetcher discovers the PNG attachment row, then AttachmentFetcher downloads it byte-for-byte")
    func endToEndPNGAttachmentDownload() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let database = try AppDatabase.makeInMemory()

        let account = AccountRecord(
            displayName: "Integration", email: "test1@otegami.test", authType: .password,
            imapHost: env.host, imapPort: env.port,
            imapSecurity: ConnectionSecurityRecord(env.imapConfig.security),
            imapAllowsInsecureTLS: env.imapConfig.allowsInsecureTLS,
            imapUsername: "test1@otegami.test"
        )
        try await database.dbWriter.write { db in try account.insert(db) }
        defer { cleanUp(accountId: account.id) }

        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }
        _ = try await session.select("INBOX")

        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .all, batchSize: 50)
        let envelope = try #require(envelopes.first { $0.messageId == "<seed-0014@otegami.test>" })

        let messageId = try await database.dbWriter.write { db -> Int64 in
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var message = MessageRecord(
                mailboxId: mailbox.id!, uid: Int64(envelope.uid), subject: envelope.subject,
                internalDate: envelope.internalDate
            )
            try message.insert(db)
            return message.id!
        }
        let message = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId)! }

        // BodyFetcher.fetchBody discovers + persists the `attachment` row
        // (the same code path a real sync uses), same as M2's own
        // integration coverage does for the body itself.
        try await BodyFetcher(database: database).fetchBody(message: message, mailboxPath: "INBOX", session: session)

        let attachment = try #require(try await database.dbWriter.read { db in
            try AttachmentRecord.filter(Column("messageId") == messageId).filter(Column("filename") == "logo.png").fetchOne(db)
        })
        #expect(attachment.localPath == nil) // not yet downloaded — only BodyFetcher's structure discovery has run

        let updated = try await AttachmentFetcher(database: database).fetchAndStore(
            attachment: attachment, accountId: account.id, messageUID: message.uid,
            mailboxPath: "INBOX", session: session
        )

        let localPath = try #require(updated.localPath)
        #expect(FileManager.default.fileExists(atPath: localPath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: localPath)) == Self.expectedPNGBytes)
    }
}
