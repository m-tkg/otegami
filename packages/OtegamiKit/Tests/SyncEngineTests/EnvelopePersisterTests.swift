import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// Task #221 (本文キャッシュ不当無効化バグ群): `EnvelopePersister.upsert`
/// re-runs on every differential/CONDSTORE sync pass, including ones that
/// only ever changed a flag (e.g. this device's own `\Seen` after reading
/// a message) — it must never reset `bodyState`/`snippet`/
/// `detectedLanguage` back to their just-inserted defaults on that kind of
/// resync, the same "flags-only resync never touches body state" contract
/// `MailboxSyncer.applyFlagsOnly`'s column-limited `update` already has.
@Suite("EnvelopePersister")
struct EnvelopePersisterTests {
    private func makeAccountAndMailbox(database: AppDatabase) async throws -> (accountId: String, mailboxId: Int64) {
        let account = AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
        try await database.dbWriter.write { db in try account.insert(db) }
        let mailboxId = try await database.dbWriter.write { db -> Int64 in
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return mailbox.id!
        }
        return (account.id, mailboxId)
    }

    private func makeEnvelope(
        uid: UInt32 = 1,
        messageId: String? = "<msg-1@otegami.test>",
        flags: MessageFlags = [],
        hasAttachmentPart: Bool = false
    ) -> FetchedEnvelope {
        FetchedEnvelope(
            uid: uid,
            messageId: messageId,
            inReplyTo: nil,
            references: [],
            subject: "件名",
            from: [EmailAddress(name: "Aiko", address: "aiko@otegami.test")],
            to: [EmailAddress(address: "test1@otegami.test")],
            cc: [],
            bcc: [],
            replyTo: [],
            date: Date(timeIntervalSince1970: 1_700_000_000),
            internalDate: Date(timeIntervalSince1970: 1_700_000_000),
            flags: flags,
            size: 512,
            parts: hasAttachmentPart
                ? [MIMEPartInfo(partId: "att-1", mimeType: "application", mimeSubtype: "pdf", filename: "invoice.pdf", isAttachment: true, size: 1)]
                : []
        )
    }

    @Test("re-upserting an already-fetched message over a flags-only resync keeps bodyState/snippet/detectedLanguage")
    func flagsOnlyResyncPreservesBodyCacheColumns() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try await makeAccountAndMailbox(database: database)

        let messageId = try await database.dbWriter.write { db -> Int64 in
            try EnvelopePersister.upsert(envelope: makeEnvelope(flags: []), mailboxId: mailboxId, accountId: accountId, db: db)
            let inserted = try MessageRecord.filter(Column("mailboxId") == mailboxId).filter(Column("uid") == 1).fetchOne(db)!
            var updated = inserted
            updated.bodyState = .fetched
            updated.snippet = "こんにちは、これはスニペットです"
            updated.detectedLanguage = "ja"
            try updated.update(db)
            return inserted.id!
        }

        // Resync with the same envelope but `\Seen` now set — mirrors this
        // device's own open-a-message flag flip getting reflected back by
        // a CONDSTORE `changedSince` response.
        try await database.dbWriter.write { db in
            try EnvelopePersister.upsert(envelope: makeEnvelope(flags: [.seen]), mailboxId: mailboxId, accountId: accountId, db: db)
        }

        let record = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) }
        #expect(record?.bodyState == .fetched)
        #expect(record?.snippet == "こんにちは、これはスニペットです")
        #expect(record?.detectedLanguage == "ja")
        // The flag change itself must still land.
        #expect(record?.flagsRaw == MessageFlags.seen.rawValue)
    }

    @Test("a brand-new envelope (no existing row) is inserted with bodyState .notFetched")
    func newEnvelopeInsertsAsNotFetched() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try await makeAccountAndMailbox(database: database)

        try await database.dbWriter.write { db in
            try EnvelopePersister.upsert(envelope: makeEnvelope(), mailboxId: mailboxId, accountId: accountId, db: db)
        }

        let record = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == mailboxId).filter(Column("uid") == 1).fetchOne(db)
        }
        #expect(record?.bodyState == .notFetched)
    }

    @Test("hasAttachments, once true from a body fetch, survives a resync whose envelope-time BODYSTRUCTURE reports none")
    func hasAttachmentsUpgradeSurvivesResync() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try await makeAccountAndMailbox(database: database)

        let messageId = try await database.dbWriter.write { db -> Int64 in
            // Initial sync: envelope-time BODYSTRUCTURE reports no parts.
            try EnvelopePersister.upsert(envelope: makeEnvelope(hasAttachmentPart: false), mailboxId: mailboxId, accountId: accountId, db: db)
            let inserted = try MessageRecord.filter(Column("mailboxId") == mailboxId).filter(Column("uid") == 1).fetchOne(db)!
            #expect(inserted.hasAttachments == false)
            // `BodyFetcher.performFetch` later upgrades it once the actual
            // body's parts are seen.
            var withAttachment = inserted
            withAttachment.hasAttachments = true
            try withAttachment.update(db)
            return inserted.id!
        }

        // A later resync's envelope still reports no parts (e.g. a server
        // that only returns BODYSTRUCTURE inconsistently) — must not
        // revert `hasAttachments` back to `false`.
        try await database.dbWriter.write { db in
            try EnvelopePersister.upsert(envelope: makeEnvelope(flags: [.seen], hasAttachmentPart: false), mailboxId: mailboxId, accountId: accountId, db: db)
        }

        let record = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) }
        #expect(record?.hasAttachments == true)
    }

    @Test("a resync whose envelope now reports an attachment sets hasAttachments even if it was false before")
    func hasAttachmentsUpgradesFromEnvelopeToo() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, mailboxId) = try await makeAccountAndMailbox(database: database)

        try await database.dbWriter.write { db in
            try EnvelopePersister.upsert(envelope: makeEnvelope(hasAttachmentPart: false), mailboxId: mailboxId, accountId: accountId, db: db)
        }
        try await database.dbWriter.write { db in
            try EnvelopePersister.upsert(envelope: makeEnvelope(flags: [.seen], hasAttachmentPart: true), mailboxId: mailboxId, accountId: accountId, db: db)
        }

        let record = try await database.dbWriter.read { db in
            try MessageRecord.filter(Column("mailboxId") == mailboxId).filter(Column("uid") == 1).fetchOne(db)
        }
        #expect(record?.hasAttachments == true)
    }
}
