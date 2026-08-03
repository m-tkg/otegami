import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

@Suite("BodyCacheStateReconciler")
struct BodyCacheStateReconcilerTests {
    private func makeDatabaseWithMessage(bodyState: MessageBodyState, hasBodyRow: Bool) throws -> (database: AppDatabase, messageId: Int64) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@otegami.test"
        )
        let messageId = try database.dbWriter.write { db -> Int64 in
            try account.insert(db)
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var message = MessageRecord(
                mailboxId: mailbox.id!,
                uid: 1,
                subject: "件名",
                internalDate: Date(timeIntervalSince1970: 1_700_000_000),
                bodyState: bodyState
            )
            try message.insert(db)
            if hasBodyRow {
                var body = MessageBodyRecord(messageId: message.id!, plainText: "本文")
                try body.insert(db)
            }
            return message.id!
        }
        return (database, messageId)
    }

    @Test("a .fetching row with a cached body row resolves to .fetched")
    func fetchingWithBodyResolvesToFetched() throws {
        let (database, messageId) = try makeDatabaseWithMessage(bodyState: .fetching, hasBodyRow: true)

        try database.dbWriter.write { db in try BodyCacheStateReconciler.resetStuckFetchingStates(db: db) }

        let updated = try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) }
        #expect(updated?.bodyState == .fetched)
    }

    @Test("a .fetching row with no cached body row resolves to .notFetched")
    func fetchingWithoutBodyResolvesToNotFetched() throws {
        let (database, messageId) = try makeDatabaseWithMessage(bodyState: .fetching, hasBodyRow: false)

        try database.dbWriter.write { db in try BodyCacheStateReconciler.resetStuckFetchingStates(db: db) }

        let updated = try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) }
        #expect(updated?.bodyState == .notFetched)
    }

    @Test("a .fetched row is left untouched, even with no body row")
    func fetchedRowUntouched() throws {
        let (database, messageId) = try makeDatabaseWithMessage(bodyState: .fetched, hasBodyRow: false)

        try database.dbWriter.write { db in try BodyCacheStateReconciler.resetStuckFetchingStates(db: db) }

        let updated = try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) }
        #expect(updated?.bodyState == .fetched)
    }

    @Test("a .notFetched row is left untouched")
    func notFetchedRowUntouched() throws {
        let (database, messageId) = try makeDatabaseWithMessage(bodyState: .notFetched, hasBodyRow: false)

        try database.dbWriter.write { db in try BodyCacheStateReconciler.resetStuckFetchingStates(db: db) }

        let updated = try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) }
        #expect(updated?.bodyState == .notFetched)
    }
}
