import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// Covers `DraftQuery.unifiedRequest` (Drafts IMAP sync milestone): the
/// merge of local `draftMessage` rows and server-origin messages living
/// directly in a `MailboxRoleRecord.drafts` mailbox, with the dedup rule
/// that keeps a draft mid-edit from appearing twice — see
/// `DraftMessageRecord`'s doc comment for the full design.
@Suite("DraftQuery")
struct DraftQueryTests {
    private func makeDatabase() throws -> (database: AppDatabase, accountId: String, draftsMailboxId: Int64) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let draftsMailboxId = try database.dbWriter.write { db -> Int64 in
            var drafts = MailboxRecord(accountId: account.id, path: "Drafts", displayPath: "Drafts", role: .drafts, uidValidity: 1)
            try drafts.insert(db)
            return drafts.id!
        }
        return (database, account.id, draftsMailboxId)
    }

    @discardableResult
    private func insertServerMessage(mailboxId: Int64, uid: Int64, subject: String, date: Date, db: Database) throws -> Int64 {
        var message = MessageRecord(mailboxId: mailboxId, uid: uid, subject: subject, date: date, internalDate: date)
        try message.insert(db)
        return message.id!
    }

    @Test("includes both a local draft and a server-origin one, newest first")
    func mergesLocalAndServerRows() throws {
        let (database, accountId, draftsMailboxId) = try makeDatabase()
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(3600)

        try database.dbWriter.write { db in
            var local = DraftMessageRecord(accountId: accountId, toAddresses: [], subject: "ローカル下書き", plainTextBody: "", updatedAt: newer)
            try local.insert(db)
            try insertServerMessage(mailboxId: draftsMailboxId, uid: 1, subject: "サーバの下書き", date: older, db: db)
        }

        let items = try database.dbWriter.read { db in try DraftQuery.unifiedRequest(accountIds: [accountId], db: db) }
        #expect(items.map(\.subject) == ["ローカル下書き", "サーバの下書き"])
    }

    @Test("a server message claimed by a local draft's serverMailboxId/serverUid is excluded (no duplicate row)")
    func excludesServerMessageClaimedByALocalDraft() throws {
        let (database, accountId, draftsMailboxId) = try makeDatabase()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try database.dbWriter.write { db in
            // The server copy this local row is about to replace (or
            // already replaced, on a UIDPLUS-supporting server) — uid 1.
            var local = DraftMessageRecord(
                accountId: accountId, toAddresses: [], subject: "編集中の下書き", plainTextBody: "",
                serverMailboxId: draftsMailboxId, serverUid: 1, serverUidValidity: 1, updatedAt: now
            )
            try local.insert(db)
            try insertServerMessage(mailboxId: draftsMailboxId, uid: 1, subject: "編集中の下書き(旧)", date: now, db: db)
            // An unrelated, unclaimed server draft (uid 2) must still show up.
            try insertServerMessage(mailboxId: draftsMailboxId, uid: 2, subject: "別の下書き", date: now.addingTimeInterval(-60), db: db)
        }

        let items = try database.dbWriter.read { db in try DraftQuery.unifiedRequest(accountIds: [accountId], db: db) }
        #expect(items.count == 2)
        #expect(items.contains { $0.subject == "編集中の下書き" })
        #expect(items.contains { $0.subject == "別の下書き" })
        #expect(!items.contains { $0.subject == "編集中の下書き(旧)" })
    }

    @Test("a purely local draft never uploaded (no serverUid) never excludes anything")
    func localOnlyDraftDoesNotAffectServerRows() throws {
        let (database, accountId, draftsMailboxId) = try makeDatabase()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try database.dbWriter.write { db in
            var local = DraftMessageRecord(accountId: accountId, toAddresses: [], subject: "未アップロード", plainTextBody: "", updatedAt: now)
            try local.insert(db)
            try insertServerMessage(mailboxId: draftsMailboxId, uid: 5, subject: "サーバ下書き", date: now, db: db)
        }

        let items = try database.dbWriter.read { db in try DraftQuery.unifiedRequest(accountIds: [accountId], db: db) }
        #expect(items.count == 2)
    }

    @Test("empty accountIds returns no rows")
    func emptyAccountIdsReturnsNothing() throws {
        let (database, _, _) = try makeDatabase()
        let items = try database.dbWriter.read { db in try DraftQuery.unifiedRequest(accountIds: [], db: db) }
        #expect(items.isEmpty)
    }
}
