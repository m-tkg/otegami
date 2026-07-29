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

    @Test("v25 migration backfills sortOrder to match createdAt order for pre-existing accounts")
    func v25BackfillsSortOrderInCreatedAtOrder() throws {
        // Same "hand-insert against a frozen pre-migration schema, then
        // migrate the rest of the way" shape as `v21RepairsDisplayPath` —
        // exercises the migration's backfill against genuinely pre-v25 rows
        // (no `sortOrder` column at all yet), not rows built with today's
        // `AccountRecord` initializer (which always has one).
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.migrator
        try migrator.migrate(dbQueue, upTo: "v24")

        // Inserted in an order that does *not* match `createdAt` order, to
        // confirm the backfill actually sorts by `createdAt` rather than
        // insertion/rowid order.
        let accounts = [
            (id: "third", createdAt: Date(timeIntervalSince1970: 3000)),
            (id: "first", createdAt: Date(timeIntervalSince1970: 1000)),
            (id: "second", createdAt: Date(timeIntervalSince1970: 2000)),
        ]
        try dbQueue.write { db in
            for account in accounts {
                try db.execute(
                    sql: """
                        INSERT INTO account
                            (id, displayName, email, authType, kind, needsReauth,
                             imapHost, imapPort, imapSecurity, imapAllowsInsecureTLS, imapUsername,
                             smtpAllowsInsecureTLS, createdAt, updatedAt)
                        VALUES (?, ?, ?, 'password', 'generic', 0, ?, ?, 'plain', 0, ?, 0, ?, ?)
                        """,
                    arguments: [
                        account.id, account.id, "\(account.id)@x.test",
                        "localhost", 1143, "\(account.id)@x.test",
                        account.createdAt, account.createdAt,
                    ]
                )
            }
        }

        try migrator.migrate(dbQueue)

        let sortOrders = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, sortOrder FROM account")
        }.reduce(into: [String: Int]()) { result, row in
            result[row["id"]] = row["sortOrder"]
        }
        #expect(sortOrders["first"] == 0)
        #expect(sortOrders["second"] == 1)
        #expect(sortOrders["third"] == 2)
    }

    @Test("v35 migration backfills stale (pre-dedup) thread.messageCount/unreadCount values")
    func v35BackfillsDeduplicatedThreadAggregates() throws {
        // Same "hand-insert against a frozen pre-migration schema, then
        // migrate the rest of the way" shape as `v21RepairsDisplayPath` —
        // exercises the migration's backfill, not just `ThreadAssigner
        // .recomputeAllAggregates(db:)` called directly (already covered
        // unit-level by `ThreadAggregateBackfillTests`). Record-based
        // inserts (not raw SQL) are safe here specifically because v35
        // itself adds no columns — `AccountRecord`/`MailboxRecord`
        // /`MessageRecord`/`ThreadRecord`'s Swift shape already matches the
        // schema exactly as it stood at v34 (the last migration to alter
        // any of those tables' columns), unlike `v21RepairsDisplayPath`'s
        // hand-inserted `mailbox` row, which predates `mailbox.isHidden`
        // (added in v26).
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.migrator
        try migrator.migrate(dbQueue, upTo: "v34")

        let account = AccountRecord(
            displayName: "Gmail", email: "g@example.test", authType: .oauth2, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "g@example.test"
        )
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadId = try dbQueue.write { db -> Int64 in
            try account.insert(db)
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var allMail = MailboxRecord(accountId: account.id, path: "[Gmail]/All Mail", displayPath: "All Mail", role: .all)
            allMail = try allMail.upsertAndFetch(db, onConflict: ["accountId", "path"])

            // `messageCount: 3`/`unreadCount: 3` — a pre-a54f585 raw
            // row-count write for what's actually one physical, unread
            // email synced into both INBOX and All Mail (the real-device
            // report this migration fixes: badge said 3, thread had 1).
            var thread = ThreadRecord(accountId: account.id, lastMessageDate: base, messageCount: 3, unreadCount: 3)
            try thread.insert(db)
            var allMailMessage = MessageRecord(
                mailboxId: allMail.id!, uid: 1, date: base, internalDate: base,
                flagsRaw: 0, gmailMessageId: 42, threadId: thread.id
            )
            try allMailMessage.insert(db)
            var inboxMessage = MessageRecord(
                mailboxId: inbox.id!, uid: 1, date: base, internalDate: base,
                flagsRaw: 0, gmailMessageId: 42, threadId: thread.id
            )
            try inboxMessage.insert(db)
            return thread.id!
        }

        try migrator.migrate(dbQueue)

        let (messageCount, unreadCount) = try dbQueue.read { db -> (Int, Int) in
            let row = try Row.fetchOne(db, sql: "SELECT messageCount, unreadCount FROM thread WHERE id = ?", arguments: [threadId])!
            return (row["messageCount"], row["unreadCount"])
        }
        #expect(messageCount == 1, "the INBOX/All-Mail duplicate must collapse to one message after the v35 backfill")
        #expect(unreadCount == 1)
    }

    @Test("sortOrder round-trips, and a fresh account defaults to 0")
    func roundTripsAccountSortOrder() throws {
        let database = try AppDatabase.makeInMemory()
        var account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        #expect(account.sortOrder == 0)
        try database.dbWriter.write { db in try account.insert(db) }

        account.sortOrder = 5
        try database.dbWriter.write { db in try account.update(db) }

        let fetched = try database.dbWriter.read { db in try AccountRecord.fetchOne(db, key: account.id) }
        #expect(fetched?.sortOrder == 5)
    }

    /// Task #66 (v28): `calendarInviteResponse` round-trips one row per
    /// message, replacing (not accumulating) on re-response, and cleans
    /// itself up when the owning `message` row is deleted.
    @Test("calendarInviteResponse round-trips, upserts one row per message, and cascade-deletes with its message")
    func roundTripsCalendarInviteResponse() throws {
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

        var response = CalendarInviteResponseRecord(
            messageId: messageId, partStat: .accepted,
            respondedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try database.dbWriter.write { db in try response.insert(db) }

        let fetched = try database.dbWriter.read { db in
            try CalendarInviteResponseRecord.filter(Column("messageId") == messageId).fetchOne(db)
        }
        #expect(fetched?.partStat == .accepted)

        // Re-responding (e.g. tapping 辞退 after having tapped 承諾)
        // replaces the row on `messageId` rather than erroring on a unique
        // constraint or accumulating a second row.
        try database.dbWriter.write { db in
            try CalendarInviteResponseRecord.filter(Column("messageId") == messageId).deleteAll(db)
            response = CalendarInviteResponseRecord(messageId: messageId, partStat: .declined)
            try response.insert(db)
        }
        let afterReResponse = try database.dbWriter.read { db in
            try CalendarInviteResponseRecord.filter(Column("messageId") == messageId).fetchAll(db)
        }
        #expect(afterReResponse.count == 1)
        #expect(afterReResponse.first?.partStat == .declined)

        try database.dbWriter.write { db in _ = try MessageRecord.deleteOne(db, key: messageId) }
        let afterMessageDelete = try database.dbWriter.read { db in
            try CalendarInviteResponseRecord.filter(Column("messageId") == messageId).fetchAll(db)
        }
        #expect(afterMessageDelete.isEmpty)
    }
}
