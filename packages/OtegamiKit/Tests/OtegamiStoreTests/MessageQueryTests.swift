import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

@Suite("MessageQuery")
struct MessageQueryTests {
    @Test("lists messages for a mailbox, newest internalDate first")
    func listsNewestFirst() throws {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }

        let (inboxId, otherId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var other = MailboxRecord(accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive)
            other = try other.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return (inbox.id!, other.id!)
        }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            var m1 = MessageRecord(mailboxId: inboxId, uid: 1, subject: "oldest", internalDate: base)
            try m1.insert(db)
            var m2 = MessageRecord(mailboxId: inboxId, uid: 2, subject: "newest", internalDate: base.addingTimeInterval(3600))
            try m2.insert(db)
            var m3 = MessageRecord(mailboxId: inboxId, uid: 3, subject: "middle", internalDate: base.addingTimeInterval(1800))
            try m3.insert(db)
            // A message in a different mailbox must not leak into INBOX's list.
            var m4 = MessageRecord(mailboxId: otherId, uid: 1, subject: "elsewhere", internalDate: base.addingTimeInterval(7200))
            try m4.insert(db)
        }

        let subjects = try database.dbWriter.read { db in
            try MessageQuery.request(mailboxId: inboxId).fetchAll(db).map(\.subject)
        }
        #expect(subjects == ["newest", "middle", "oldest"])
    }

    @Test("maxUID reflects the highest stored UID, nil when empty")
    func maxUID() throws {
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

        let empty = try database.dbWriter.read { db in try MessageQuery.maxUID(mailboxId: mailboxId, db: db) }
        #expect(empty == nil)

        try database.dbWriter.write { db in
            var m1 = MessageRecord(mailboxId: mailboxId, uid: 5, internalDate: Date())
            try m1.insert(db)
            var m2 = MessageRecord(mailboxId: mailboxId, uid: 12, internalDate: Date())
            try m2.insert(db)
        }

        let max = try database.dbWriter.read { db in try MessageQuery.maxUID(mailboxId: mailboxId, db: db) }
        #expect(max == 12)
    }
}
