import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

@Suite("AttachmentFetcher")
struct AttachmentFetcherTests {
    /// Inserts an account/mailbox/message/attachment row (as if
    /// `BodyFetcher.fetchBody` had already run and discovered this part)
    /// and returns everything `AttachmentFetcher.fetchAndStore` needs.
    private func makeAttachedMessage(
        database: AppDatabase,
        filename: String? = "invoice.pdf",
        partId: String = "1.2"
    ) async throws -> (accountId: String, message: MessageRecord, attachment: AttachmentRecord) {
        let account = AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
        try await database.dbWriter.write { db in try account.insert(db) }

        return try await database.dbWriter.write { db in
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var message = MessageRecord(
                mailboxId: mailbox.id!,
                uid: 5,
                subject: "添付あり",
                internalDate: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try message.insert(db)
            // size: 0 (unlike `BodyFetcherTests`' fixtures, which already
            // know their `BODYSTRUCTURE`-reported size) so
            // `fetchesAndPersists` below can assert `AttachmentFetcher`
            // fills it in from the downloaded payload's actual length.
            var attachment = AttachmentRecord(
                messageId: message.id!,
                partId: partId,
                filename: filename,
                mimeType: "application",
                mimeSubtype: "pdf",
                size: 0
            )
            try attachment.insert(db)
            return (account.id, message, attachment)
        }
    }

    /// Cleans up whatever `AttachmentFetcher.storageURL` created for
    /// `accountId`, so a test run doesn't leave files behind on the host
    /// (there's no in-memory filesystem equivalent to `AppDatabase
    /// .makeInMemory()` to isolate this the way DB state is isolated).
    private func cleanUp(accountId: String) {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        let dir = base.appendingPathComponent("otegami/Attachments/\(accountId)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("downloads and persists an attachment's bytes, updates localPath")
    func fetchesAndPersists() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, message, attachment) = try await makeAttachedMessage(database: database)
        defer { cleanUp(accountId: accountId) }

        let payload = Data("%PDF-1.4 fake pdf bytes".utf8)
        let script = FakeIMAPSession.Script(
            attachmentDataByPath: ["INBOX": [UInt32(message.uid): [attachment.partId: payload]]]
        )
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        let fetcher = AttachmentFetcher(database: database)
        let updated = try await fetcher.fetchAndStore(
            attachment: attachment, accountId: accountId, messageUID: message.uid,
            mailboxPath: "INBOX", session: session
        )

        let localPath = try #require(updated.localPath)
        #expect(FileManager.default.fileExists(atPath: localPath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: localPath)) == payload)
        #expect(updated.size == payload.count)

        // Persisted to the database, not just returned.
        let stored = try await database.dbWriter.read { db in try AttachmentRecord.fetchOne(db, key: attachment.id) }
        #expect(stored?.localPath == localPath)
    }

    @Test("a nil filename still produces a valid, sanitized storage path")
    func nilFilenameStillWorks() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, message, attachment) = try await makeAttachedMessage(database: database, filename: nil)
        defer { cleanUp(accountId: accountId) }

        let payload = Data([0x01, 0x02, 0x03])
        let script = FakeIMAPSession.Script(
            attachmentDataByPath: ["INBOX": [UInt32(message.uid): [attachment.partId: payload]]]
        )
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        let updated = try await AttachmentFetcher(database: database).fetchAndStore(
            attachment: attachment, accountId: accountId, messageUID: message.uid,
            mailboxPath: "INBOX", session: session
        )
        let localPath = try #require(updated.localPath)
        #expect(FileManager.default.fileExists(atPath: localPath))
    }

    @Test("already-downloaded attachment (localPath exists on disk) is returned without touching the network")
    func skipsNetworkWhenAlreadyDownloaded() async throws {
        let database = try AppDatabase.makeInMemory()
        var (accountId, message, attachment) = try await makeAttachedMessage(database: database)
        defer { cleanUp(accountId: accountId) }

        // Pre-populate localPath with a real file, as if a previous fetch
        // (or a racing cid-image resolve) had already completed.
        let existingURL = try AttachmentFetcher.storageURL(
            accountId: accountId, messageId: message.id!, attachmentId: attachment.id!, filename: attachment.filename
        )
        try FileManager.default.createDirectory(at: existingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existingPayload = Data("already here".utf8)
        try existingPayload.write(to: existingURL)
        attachment.localPath = existingURL.path
        let attachmentToPersist = attachment
        try await database.dbWriter.write { db in try attachmentToPersist.update(db) }

        // No scripted attachment data at all — a network fetch would throw.
        let script = FakeIMAPSession.Script()
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        let updated = try await AttachmentFetcher(database: database).fetchAndStore(
            attachment: attachment, accountId: accountId, messageUID: message.uid,
            mailboxPath: "INBOX", session: session
        )
        #expect(updated.localPath == existingURL.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: updated.localPath!)) == existingPayload)
    }

    @Test("two attachments on the same message with the same filename don't collide on disk")
    func sameFilenameDifferentAttachmentsDontCollide() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, message, first) = try await makeAttachedMessage(database: database, filename: "image.png", partId: "2")
        defer { cleanUp(accountId: accountId) }

        let second = try await database.dbWriter.write { db -> AttachmentRecord in
            var attachment = AttachmentRecord(
                messageId: message.id!, partId: "3", filename: "image.png",
                mimeType: "image", mimeSubtype: "png", size: 2
            )
            try attachment.insert(db)
            return attachment
        }

        let firstPayload = Data([0xAA])
        let secondPayload = Data([0xBB])
        let script = FakeIMAPSession.Script(attachmentDataByPath: [
            "INBOX": [UInt32(message.uid): [first.partId: firstPayload, second.partId: secondPayload]],
        ])
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        let fetcher = AttachmentFetcher(database: database)
        let updatedFirst = try await fetcher.fetchAndStore(
            attachment: first, accountId: accountId, messageUID: message.uid, mailboxPath: "INBOX", session: session
        )
        let updatedSecond = try await fetcher.fetchAndStore(
            attachment: second, accountId: accountId, messageUID: message.uid, mailboxPath: "INBOX", session: session
        )

        #expect(updatedFirst.localPath != updatedSecond.localPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: updatedFirst.localPath!)) == firstPayload)
        #expect(try Data(contentsOf: URL(fileURLWithPath: updatedSecond.localPath!)) == secondPayload)
    }
}
