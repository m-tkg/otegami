import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

@Suite("AppDatabase")
struct AppDatabaseTests {
    @Test("migrates cleanly in memory and is idempotent to reopen")
    func migratesCleanly() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.read { db in
            try #expect(db.tableExists("account"))
            try #expect(db.tableExists("mailbox"))
            try #expect(db.tableExists("message"))
            try #expect(db.tableExists("messageReference"))
            try #expect(db.tableExists("messageBody"))
            try #expect(db.tableExists("attachment"))
            try #expect(db.tableExists("thread"))
            try #expect(db.tableExists("opQueue"))
            try #expect(db.tableExists("messageTranslation"))
            try #expect(db.columns(in: "message").contains { $0.name == "detectedLanguage" })
        }

        // Re-running the migrator against an already-migrated database
        // (as happens on every app launch) must be a no-op, not an error.
        try AppDatabase.migrator.migrate(database.dbWriter)
    }

    @Test("saves an account and reads it back")
    func savesAccount() throws {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test One",
            email: "test1@otegami.test",
            authType: .password,
            imapHost: "localhost",
            imapPort: 1143,
            imapSecurity: .plain,
            imapUsername: "test1@otegami.test",
            // Whole seconds: GRDB's default `Date` storage round-trips
            // through millisecond-precision text, so an unrounded `Date()`
            // would spuriously fail an exact equality check below.
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try database.dbWriter.write { db in
            try account.insert(db)
        }

        let fetched = try database.dbWriter.read { db in
            try AccountRecord.fetchOne(db, key: account.id)
        }
        #expect(fetched == account)
    }

    @Test("D: an account's labelColorKey round-trips, and defaults to nil for an existing row")
    func roundTripsAccountLabelColorKey() throws {
        let database = try AppDatabase.makeInMemory()
        var account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }

        let fetchedBeforePick = try database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) }
        #expect(fetchedBeforePick?.labelColorKey == nil)

        account.labelColorKey = "coral"
        try database.dbWriter.write { db in try account.update(db) }

        let fetchedAfterPick = try database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) }
        #expect(fetchedAfterPick?.labelColorKey == "coral")
    }

    @Test("F: a signatureTemplate round-trips (JSON-encoded accountIds), and account.defaultSignatureId self-heals to nil when the signature is deleted")
    func roundTripsSignatureTemplateAndDefaultSignatureSetNull() throws {
        let database = try AppDatabase.makeInMemory()
        var account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }

        var signature = SignatureTemplateRecord(name: "仕事用", body: "よろしくお願いします。", accountIds: [account.id])
        try database.dbWriter.write { db in try signature.insert(db) }
        #expect(signature.id != nil)

        let fetchedSignature = try database.dbWriter.read { db in try SignatureTemplateRecord.fetchOne(db, key: signature.id) }
        #expect(fetchedSignature?.accountIds == [account.id])
        #expect(fetchedSignature?.body == "よろしくお願いします。")

        account.defaultSignatureId = signature.id
        try database.dbWriter.write { db in try account.update(db) }
        let fetchedAccount = try database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) }
        #expect(fetchedAccount?.defaultSignatureId == signature.id)

        // Deleting the signature should self-heal the account's
        // `defaultSignatureId` back to nil via `onDelete: .setNull` (v24
        // migration) — no manual cleanup code needed at the call site.
        try database.dbWriter.write { db in _ = try SignatureTemplateRecord.deleteOne(db, key: signature.id) }
        let fetchedAccountAfterDelete = try database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) }
        #expect(fetchedAccountAfterDelete?.defaultSignatureId == nil)
    }

    @Test("upserting a mailbox on (accountId, path) is idempotent")
    func upsertsMailboxIdempotently() throws {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }

        for messageCount in [3, 7] {
            try database.dbWriter.write { db in
                var mailbox = MailboxRecord(
                    accountId: account.id, path: "INBOX", displayPath: "INBOX",
                    role: .inbox, messageCount: messageCount
                )
                mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            }
        }

        let mailboxes = try database.dbWriter.read { db in
            try MailboxRecord.filter(Column("accountId") == account.id).fetchAll(db)
        }
        #expect(mailboxes.count == 1)
        #expect(mailboxes.first?.messageCount == 7)
    }

    @Test("round-trips a message with JSON-encoded address arrays")
    func roundTripsMessageAddresses() throws {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }

        let mailboxId = try database.dbWriter.write { db -> Int64 in
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return mailbox.id!
        }

        var message = MessageRecord(
            mailboxId: mailboxId,
            uid: 1,
            subject: "ようこそ otegami へ",
            fromAddresses: [EmailAddress(name: "愛子", address: "aiko@otegami.test")],
            toAddresses: [EmailAddress(address: "test1@otegami.test")],
            internalDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try database.dbWriter.write { db in try message.insert(db) }

        let fetched = try database.dbWriter.read { db in
            try MessageRecord.fetchOne(db, key: message.id)
        }
        #expect(fetched?.subject == "ようこそ otegami へ")
        #expect(fetched?.fromAddresses.first?.name == "愛子")
        #expect(fetched?.fromAddresses.first?.address == "aiko@otegami.test")
        #expect(fetched?.toAddresses.first?.address == "test1@otegami.test")
    }

    @Test("v21 migration repairs displayPath values written before ModifiedUTF7 decoding existed")
    func v21RepairsDisplayPath() throws {
        // Migrates only up to v20 first, then hand-inserts a `mailbox` row
        // shaped like what pre-fix `AccountSyncer.upsertMailboxes` actually
        // wrote — `displayPath` holding the *raw* modified-UTF-7 path,
        // exactly like `MailCoreIMAPSession.mailboxInfo(from:)` produced
        // before it started calling `ModifiedUTF7.decode` — so this test
        // exercises the migration's repair logic against genuinely
        // pre-migration data, not just a record built with today's
        // (already-correct) `MailboxRecord` initializer.
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.migrator
        try migrator.migrate(dbQueue, upTo: "v20")

        let account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        try dbQueue.write { db in
            // Raw SQL, not `account.insert(db)` — deliberately, and for the
            // same reason the `mailbox` row right below is raw SQL too: the
            // schema is frozen at v20 here, but `AccountRecord`'s Swift
            // definition (and the columns GRDB's Codable-based `insert`
            // derives from it) reflects *every* migration currently
            // registered in `AppDatabase.migrator`, including ones after
            // v20 (e.g. v22's `labelColorKey`) that haven't run against
            // this `dbQueue` yet. `account.insert(db)` would try to write
            // to a column that doesn't exist yet at this schema version.
            try db.execute(
                sql: """
                    INSERT INTO account
                        (id, displayName, email, authType, kind, needsReauth,
                         imapHost, imapPort, imapSecurity, imapAllowsInsecureTLS, imapUsername,
                         smtpAllowsInsecureTLS, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    account.id, account.displayName, account.email, account.authType.rawValue, account.kind.rawValue, false,
                    account.imapHost, account.imapPort, account.imapSecurity.rawValue, false, account.imapUsername,
                    false, account.createdAt, account.updatedAt,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO mailbox
                        (accountId, path, displayPath, delimiter, role, attributesRaw,
                         uidValidity, uidNext, highestModSeq, messageCount)
                    VALUES (?, ?, ?, ?, 'all', 0, 0, 0, 0, 0)
                    """,
                arguments: [
                    account.id, "[Gmail]/&MFkweTBmMG4w4TD8MOs-", "[Gmail]/&MFkweTBmMG4w4TD8MOs-", "/",
                ]
            )
        }

        try migrator.migrate(dbQueue)

        let displayPath = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT displayPath FROM mailbox WHERE accountId = ?", arguments: [account.id])
        }
        #expect(displayPath == "[Gmail]/すべてのメール")
    }

    @Test("round-trips a messageTranslation row, including its JSON-encoded paragraphs")
    func roundTripsMessageTranslation() throws {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }

        let messageId = try database.dbWriter.write { db -> Int64 in
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var message = MessageRecord(mailboxId: mailbox.id!, uid: 1, internalDate: Date(timeIntervalSince1970: 1_700_000_000))
            try message.insert(db)
            return message.id!
        }

        let translation = MessageTranslationRecord(
            messageId: messageId,
            sourceLanguage: "en",
            targetLanguage: "ja",
            translatedText: "こんにちは\n\nよろしくお願いします",
            paragraphs: [
                TranslatedParagraph(original: "Hello", translated: "こんにちは"),
                TranslatedParagraph(original: "Best regards", translated: "よろしくお願いします"),
            ],
            engineIdentifier: "foundation-models",
            translatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try database.dbWriter.write { db in try translation.insert(db) }

        let fetched = try database.dbWriter.read { db in
            try MessageTranslationRecord.fetchOne(db, key: messageId)
        }
        #expect(fetched == translation)

        // `save(db)` (used by `MessageTranslator`) upserts on the
        // `messageId` primary key rather than throwing a unique-constraint
        // error the second time.
        var replacement = translation
        replacement.translatedText = "更新後の翻訳"
        try database.dbWriter.write { db in try replacement.save(db) }
        let refetched = try database.dbWriter.read { db in
            try MessageTranslationRecord.fetchOne(db, key: messageId)
        }
        #expect(refetched?.translatedText == "更新後の翻訳")
    }
}
