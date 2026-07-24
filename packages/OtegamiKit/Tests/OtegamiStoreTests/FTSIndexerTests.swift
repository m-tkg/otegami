import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

@Suite("FTSIndexer")
struct FTSIndexerTests {
    private func makeDatabaseWithMessage(
        subject: String? = "件名",
        plainText: String? = nil,
        from: [EmailAddress] = [EmailAddress(name: "Alice", address: "alice@otegami.test")]
    ) throws -> (database: AppDatabase, messageId: Int64) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        let messageId = try database.dbWriter.write { db -> Int64 in
            try account.insert(db)
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var message = MessageRecord(
                mailboxId: mailbox.id!,
                uid: 1,
                subject: subject,
                fromAddresses: from,
                fromText: FTSIndexer.composeFromText(from),
                internalDate: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try message.insert(db)
            if let plainText {
                let body = MessageBodyRecord(messageId: message.id!, plainText: plainText)
                try body.insert(db)
            }
            return message.id!
        }
        return (database, messageId)
    }

    @Test("composeFromText renders name + address, and just address with no name")
    func composeFromTextRendersNameAndAddress() {
        let withName = FTSIndexer.composeFromText([EmailAddress(name: "愛子", address: "aiko@otegami.test")])
        #expect(withName == "愛子 <aiko@otegami.test>")

        let withoutName = FTSIndexer.composeFromText([EmailAddress(address: "bare@otegami.test")])
        #expect(withoutName == "bare@otegami.test")
    }

    @Test("reindex indexes subject, plainText, and fromText so a MATCH on each hits")
    func reindexIndexesAllThreeColumns() throws {
        let (database, messageId) = try makeDatabaseWithMessage(
            subject: "明日の打ち合わせについて",
            plainText: "資料を添付します。よろしくお願いします。",
            from: [EmailAddress(name: "田中太郎", address: "tanaka@otegami.test")]
        )
        try database.dbWriter.write { db in try FTSIndexer.reindex(messageId: messageId, db: db) }

        try database.dbWriter.read { db in
            // Every MATCH query here is >= 3 characters — trigram's own
            // floor, see `SearchQueryTests`'s boundary test for what
            // happens below it.
            try #expect(matches(query: "\"打ち合\"", db: db).contains(messageId))
            try #expect(matches(query: "\"資料を添\"", db: db).contains(messageId))
            try #expect(matches(query: "\"田中太\"", db: db).contains(messageId))
        }
    }

    @Test("delete removes the row; a MATCH that hit before no longer does")
    func deleteRemovesRow() throws {
        let (database, messageId) = try makeDatabaseWithMessage(subject: "Hello World")
        try database.dbWriter.write { db in
            try FTSIndexer.reindex(messageId: messageId, db: db)
            try #expect(matches(query: "\"hel\"", db: db).contains(messageId))
            try FTSIndexer.delete(messageId: messageId, db: db)
            try #expect(matches(query: "\"hel\"", db: db).isEmpty)
        }
    }

    @Test("delete on a never-indexed rowid is a harmless no-op")
    func deleteNonexistentRowIsNoOp() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            try FTSIndexer.delete(messageId: 999_999, db: db)
        }
    }

    @Test("deleteAll removes every listed rowid, ignores an empty list")
    func deleteAllRemovesEveryRow() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            try FTSIndexer.deleteAll(messageIds: [], db: db)
            try FTSIndexer.upsert(messageId: 1, subject: "Alpha", plainText: nil, fromText: nil, db: db)
            try FTSIndexer.upsert(messageId: 2, subject: "Beta", plainText: nil, fromText: nil, db: db)
            try FTSIndexer.deleteAll(messageIds: [1, 2], db: db)
            try #expect(matches(query: "\"alp\"", db: db).isEmpty)
            try #expect(matches(query: "\"bet\"", db: db).isEmpty)
        }
    }

    @Test("upsert is delete-then-insert: re-indexing a message with new text drops the old text from the index")
    func upsertReplacesOldText() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            try FTSIndexer.upsert(messageId: 1, subject: "Original Subject", plainText: nil, fromText: nil, db: db)
            try #expect(matches(query: "\"ori\"", db: db).contains(1))
            try FTSIndexer.upsert(messageId: 1, subject: "Replaced Subject", plainText: nil, fromText: nil, db: db)
            try #expect(matches(query: "\"ori\"", db: db).isEmpty)
            try #expect(matches(query: "\"rep\"", db: db).contains(1))
        }
    }

    @Test("backfillIfNeeded indexes every message that has no row yet, and is a no-op once caught up")
    func backfillIndexesUnindexedMessages() throws {
        let (database, messageId) = try makeDatabaseWithMessage(subject: "バックフィル対象")
        try database.dbWriter.read { db in
            try #expect(matches(query: "\"バック\"", db: db).isEmpty)
        }

        try database.dbWriter.write { db in try FTSIndexer.backfillIfNeeded(db: db) }
        try database.dbWriter.read { db in
            try #expect(matches(query: "\"バック\"", db: db).contains(messageId))
        }

        // Second call: nothing pending, nothing changes (and doesn't throw).
        try database.dbWriter.write { db in try FTSIndexer.backfillIfNeeded(db: db) }
        try database.dbWriter.read { db in
            try #expect(matches(query: "\"バック\"", db: db).contains(messageId))
        }
    }

    @Test("reindex on a message with a fetched body doesn't need plainText passed in twice")
    func reindexPicksUpExistingBody() throws {
        let (database, messageId) = try makeDatabaseWithMessage(subject: "件名のみ最初", plainText: "本文はあとから届く")
        try database.dbWriter.write { db in
            // Simulates AccountSyncer.upsert's envelope-time call, before a
            // body has been fetched.
            try FTSIndexer.upsert(messageId: messageId, subject: "件名のみ最初", plainText: nil, fromText: nil, db: db)
            try #expect(matches(query: "\"本文は\"", db: db).isEmpty)

            // BodyFetcher.fetchBody's call, once the body exists in
            // messageBody: reindex re-derives plainText from the DB rather
            // than needing it threaded through by hand.
            try FTSIndexer.reindex(messageId: messageId, db: db)
            try #expect(matches(query: "\"本文は\"", db: db).contains(messageId))
        }
    }

    private func matches(query: String, db: Database) throws -> Set<Int64> {
        Set(try Int64.fetchAll(db, sql: "SELECT rowid FROM messageSearchIndex WHERE messageSearchIndex MATCH ?", arguments: [query]))
    }
}
