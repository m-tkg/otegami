import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// Covers the M10 `EXISTS`-based rewrite of `ThreadQuery.request`/
/// `unifiedInboxRequest` (docs/performance.md) — same observable behavior
/// (which threads, what order) as the pre-rewrite `SELECT DISTINCT ... JOIN`
/// form, plus the new `limit` parameter.
@Suite("ThreadQuery")
struct ThreadQueryTests {
    private func makeDatabase() throws -> (database: AppDatabase, accountId: String, inboxId: Int64, archiveId: Int64) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let (inboxId, archiveId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var archive = MailboxRecord(accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive)
            archive = try archive.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return (inbox.id!, archive.id!)
        }
        return (database, account.id, inboxId, archiveId)
    }

    /// Inserts one thread with one message in `mailboxId`, dated `date`.
    @discardableResult
    private func insertThread(accountId: String, mailboxId: Int64, uid: Int64, date: Date, db: Database) throws -> Int64 {
        var thread = ThreadRecord(accountId: accountId, lastMessageDate: date, messageCount: 1)
        try thread.insert(db)
        var message = MessageRecord(mailboxId: mailboxId, uid: uid, date: date, internalDate: date, threadId: thread.id)
        try message.insert(db)
        return thread.id!
    }

    @Test("request(mailboxId:) returns only threads with a message in that mailbox, newest first")
    func requestScopesToMailbox() throws {
        let (database, accountId, inboxId, archiveId) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (t1, t2, t3) = try database.dbWriter.write { db -> (Int64, Int64, Int64) in
            let t1 = try insertThread(accountId: accountId, mailboxId: inboxId, uid: 1, date: base, db: db)
            let t2 = try insertThread(accountId: accountId, mailboxId: inboxId, uid: 2, date: base.addingTimeInterval(3600), db: db)
            let t3 = try insertThread(accountId: accountId, mailboxId: archiveId, uid: 1, date: base.addingTimeInterval(7200), db: db)
            return (t1, t2, t3)
        }
        _ = t3

        let threadIds = try database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: inboxId).fetchAll(db).map(\.id)
        }
        #expect(threadIds == [t2, t1])
    }

    @Test("request(mailboxId:limit:) caps the result to the newest N threads")
    func requestRespectsLimit() throws {
        let (database, accountId, inboxId, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let ids = try database.dbWriter.write { db -> [Int64] in
            try (0..<10).map { i in
                try insertThread(accountId: accountId, mailboxId: inboxId, uid: Int64(i), date: base.addingTimeInterval(Double(i) * 60), db: db)
            }
        }
        let newestThree = Array(ids.reversed().prefix(3))

        let limited = try database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: inboxId, limit: 3).fetchAll(db).map(\.id)
        }
        #expect(limited == newestThree)
    }

    @Test("unifiedInboxRequest only includes inbox-role mailboxes across the given accounts")
    func unifiedInboxScopesToInboxRole() throws {
        let (database, accountId, inboxId, archiveId) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (inboxThread, _) = try database.dbWriter.write { db -> (Int64, Int64) in
            let inboxThread = try insertThread(accountId: accountId, mailboxId: inboxId, uid: 1, date: base, db: db)
            let archiveThread = try insertThread(accountId: accountId, mailboxId: archiveId, uid: 1, date: base.addingTimeInterval(60), db: db)
            return (inboxThread, archiveThread)
        }

        let threadIds = try database.dbWriter.read { db in
            try ThreadQuery.unifiedInboxRequest(accountIds: [accountId]).fetchAll(db).map(\.id)
        }
        #expect(threadIds == [inboxThread])
    }
}
