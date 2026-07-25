import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

@Suite("BodyFetcher")
struct BodyFetcherTests {
    /// Inserts an account/mailbox/message row (as if `AccountSyncer` had
    /// already run envelope sync) and returns the fully-identified
    /// `MessageRecord`, ready for `BodyFetcher.fetchBody` to act on.
    private func makeSyncedMessage(
        database: AppDatabase,
        uid: Int64 = 1,
        subject: String = "テスト"
    ) async throws -> MessageRecord {
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
                uid: uid,
                subject: subject,
                internalDate: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try message.insert(db)
            return message
        }
    }

    @Test("plain-only body: stored verbatim, snippet derived from it")
    func plainOnlyBody() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database)
        let content = MessageBodyContent(plainText: "test1 さん\n\nようこそ otegami へ。\n\nよろしくお願いします。")
        let script = FakeIMAPSession.Script(bodiesByPath: ["INBOX": [UInt32(message.uid): content]])
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        let fetcher = BodyFetcher(database: database)
        try await fetcher.fetchBody(message: message, mailboxPath: "INBOX", session: session)

        let (body, updated) = try await database.dbWriter.read { db in
            (
                try MessageBodyRecord.fetchOne(db, key: message.id),
                try MessageRecord.fetchOne(db, key: message.id)
            )
        }
        #expect(body?.plainText == content.plainText)
        #expect(body?.html == nil)
        #expect(updated?.bodyState == .fetched)
        #expect(updated?.snippet == "test1 さん ようこそ otegami へ。 よろしくお願いします。")
    }

    #if canImport(NaturalLanguage)
    @Test("fetching an English body sets message.detectedLanguage to \"en\"")
    func detectsEnglishLanguage() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database, subject: "Welcome")
        let content = MessageBodyContent(plainText: "Hi team, the quarterly report is attached. Please review it by Friday and send me your comments. Thanks!")
        let script = FakeIMAPSession.Script(bodiesByPath: ["INBOX": [UInt32(message.uid): content]])
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        try await BodyFetcher(database: database).fetchBody(message: message, mailboxPath: "INBOX", session: session)

        let updated = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: message.id) }
        #expect(updated?.detectedLanguage == "en")
    }

    @Test("fetching a Japanese body sets message.detectedLanguage to \"ja\"")
    func detectsJapaneseLanguage() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database)
        let content = MessageBodyContent(plainText: "test1 さん\n\nようこそ otegami へ。\n\nよろしくお願いします。")
        let script = FakeIMAPSession.Script(bodiesByPath: ["INBOX": [UInt32(message.uid): content]])
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        try await BodyFetcher(database: database).fetchBody(message: message, mailboxPath: "INBOX", session: session)

        let updated = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: message.id) }
        #expect(updated?.detectedLanguage == "ja")
    }
    #endif

    @Test("HTML-only body: plainText backfilled by extracting text from the HTML")
    func htmlOnlyBody() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database, subject: "HTML専用")
        let html = "<html><body><p>こんにちは、otegami です。</p><p>これはHTML専用の日本語メールです。</p></body></html>"
        let content = MessageBodyContent(html: html)
        let script = FakeIMAPSession.Script(bodiesByPath: ["INBOX": [UInt32(message.uid): content]])
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        let fetcher = BodyFetcher(database: database)
        try await fetcher.fetchBody(message: message, mailboxPath: "INBOX", session: session)

        let body = try await database.dbWriter.read { db in try MessageBodyRecord.fetchOne(db, key: message.id) }
        #expect(body?.html == html)
        #expect(body?.plainText == "こんにちは、otegami です。\nこれはHTML専用の日本語メールです。")

        let updated = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: message.id) }
        #expect(updated?.snippet == "こんにちは、otegami です。 これはHTML専用の日本語メールです。")
    }

    @Test("both plain and HTML present: both stored, plainText not overwritten by HTML extraction")
    func bothPlainAndHTMLBody() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database, subject: "両方")
        let content = MessageBodyContent(
            plainText: "プレーンテキスト版です。",
            html: "<p>HTML版です。</p>"
        )
        let script = FakeIMAPSession.Script(bodiesByPath: ["INBOX": [UInt32(message.uid): content]])
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        try await BodyFetcher(database: database).fetchBody(message: message, mailboxPath: "INBOX", session: session)

        let body = try await database.dbWriter.read { db in try MessageBodyRecord.fetchOne(db, key: message.id) }
        #expect(body?.plainText == "プレーンテキスト版です。")
        #expect(body?.html == "<p>HTML版です。</p>")
    }

    @Test("attachments and inline parts are persisted, inline detected from contentId")
    func attachmentsPersisted() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database, subject: "添付あり")
        let content = MessageBodyContent(
            plainText: "本文です。",
            html: "<p>本文です。</p><img src=\"cid:logo@otegami.test\">",
            parts: [
                MIMEPartInfo(partId: "att-1", mimeType: "application", mimeSubtype: "pdf", filename: "invoice.pdf", isAttachment: true, size: 12345),
                MIMEPartInfo(partId: "att-2", mimeType: "image", mimeSubtype: "png", contentId: "logo@otegami.test", isAttachment: false, size: 2048),
            ]
        )
        let script = FakeIMAPSession.Script(bodiesByPath: ["INBOX": [UInt32(message.uid): content]])
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        try await BodyFetcher(database: database).fetchBody(message: message, mailboxPath: "INBOX", session: session)

        let attachments = try await database.dbWriter.read { db in
            try AttachmentRecord.filter(Column("messageId") == message.id).order(Column("partId")).fetchAll(db)
        }
        #expect(attachments.count == 2)
        #expect(attachments[0].filename == "invoice.pdf")
        #expect(attachments[0].isInline == false)
        #expect(attachments[1].contentId == "logo@otegami.test")
        #expect(attachments[1].isInline == true)

        let updated = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: message.id) }
        #expect(updated?.hasAttachments == true)
    }

    @Test("re-fetching a message replaces its body and attachments rather than duplicating")
    func refetchReplacesBody() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database)
        let fetcher = BodyFetcher(database: database)

        let firstScript = FakeIMAPSession.Script(bodiesByPath: [
            "INBOX": [UInt32(message.uid): MessageBodyContent(
                plainText: "古い本文",
                parts: [MIMEPartInfo(partId: "a", mimeType: "application", mimeSubtype: "pdf", isAttachment: true, size: 1)]
            )],
        ])
        try await fetcher.fetchBody(
            message: message, mailboxPath: "INBOX",
            session: FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: firstScript)
        )

        let secondScript = FakeIMAPSession.Script(bodiesByPath: [
            "INBOX": [UInt32(message.uid): MessageBodyContent(plainText: "新しい本文")],
        ])
        try await fetcher.fetchBody(
            message: message, mailboxPath: "INBOX",
            session: FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: secondScript)
        )

        let body = try await database.dbWriter.read { db in try MessageBodyRecord.fetchOne(db, key: message.id) }
        #expect(body?.plainText == "新しい本文")

        let attachments = try await database.dbWriter.read { db in
            try AttachmentRecord.filter(Column("messageId") == message.id).fetchAll(db)
        }
        #expect(attachments.isEmpty)
    }

    @Test("a fetch failure reverts bodyState to notFetched")
    func fetchFailureRevertsBodyState() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database)
        // No scripted body for this UID: FakeIMAPSession.fetchBody throws.
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: FakeIMAPSession.Script())

        await #expect(throws: (any Error).self) {
            try await BodyFetcher(database: database).fetchBody(message: message, mailboxPath: "INBOX", session: session)
        }

        let updated = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: message.id) }
        #expect(updated?.bodyState == .notFetched)
    }

    @Test("prefetchRecent fetches only the newest not-yet-fetched messages, up to the limit")
    func prefetchRecentRespectsLimitAndOrder() async throws {
        let database = try AppDatabase.makeInMemory()
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

        let bodies: [UInt32: MessageBodyContent] = Dictionary(
            uniqueKeysWithValues: (1...10).map { uid in (UInt32(uid), MessageBodyContent(plainText: "body-\(uid)")) }
        )
        try await database.dbWriter.write { db in
            for uid in 1...10 {
                var message = MessageRecord(
                    mailboxId: mailboxId,
                    uid: Int64(uid),
                    subject: "msg-\(uid)",
                    internalDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid))
                )
                try message.insert(db)
            }
        }

        let script = FakeIMAPSession.Script(bodiesByPath: ["INBOX": bodies])
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        let fetchedCount = try await BodyFetcher(database: database)
            .prefetchRecent(mailboxId: mailboxId, mailboxPath: "INBOX", limit: 3, session: session)
        #expect(fetchedCount == 3)

        let fetchedMessages = try await database.dbWriter.read { db in
            try MessageRecord
                .filter(Column("mailboxId") == mailboxId)
                .filter(Column("bodyState") == MessageBodyState.fetched.rawValue)
                .fetchAll(db)
        }
        // Newest three UIDs (10, 9, 8) — internalDate increases with uid here.
        #expect(Set(fetchedMessages.map(\.uid)) == [10, 9, 8])
    }
}
