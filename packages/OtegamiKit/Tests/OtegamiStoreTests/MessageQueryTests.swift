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

    // MARK: - Unread counts (M10: sidebar badges)

    @Test("seenFlagBit's raw SQL literal matches MessageFlags.seen.rawValue")
    func seenFlagBitMatchesMessageFlags() {
        #expect(MessageQuery.seenFlagBit == MessageFlags.seen.rawValue)
    }

    @Test("unreadCounts groups by mailbox and ignores seen messages")
    func unreadCountsPerMailbox() throws {
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

        try database.dbWriter.write { db in
            var unread1 = MessageRecord(mailboxId: inboxId, uid: 1, internalDate: Date())
            try unread1.insert(db)
            var unread2 = MessageRecord(mailboxId: inboxId, uid: 2, internalDate: Date())
            try unread2.insert(db)
            var seen = MessageRecord(mailboxId: inboxId, uid: 3, internalDate: Date(), flagsRaw: MessageFlags.seen.rawValue)
            try seen.insert(db)
            var archiveUnread = MessageRecord(mailboxId: archiveId, uid: 1, internalDate: Date())
            try archiveUnread.insert(db)
        }

        let counts = try database.dbWriter.read { db in try MessageQuery.unreadCounts(accountId: account.id, db: db) }
        #expect(counts[inboxId] == 2)
        #expect(counts[archiveId] == 1)
    }

    @Test("unifiedInboxUnreadCount sums unread across accounts, inbox-role mailboxes only")
    func unifiedInboxUnreadCount() throws {
        let database = try AppDatabase.makeInMemory()
        let account1 = AccountRecord(
            displayName: "A1", email: "a1@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "a1@x.test"
        )
        let account2 = AccountRecord(
            displayName: "A2", email: "a2@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "a2@x.test"
        )
        try database.dbWriter.write { db in
            try account1.insert(db)
            try account2.insert(db)
        }
        let (inbox1, archive1, inbox2) = try database.dbWriter.write { db -> (Int64, Int64, Int64) in
            var i1 = MailboxRecord(accountId: account1.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            i1 = try i1.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var a1 = MailboxRecord(accountId: account1.id, path: "Archive", displayPath: "Archive", role: .archive)
            a1 = try a1.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var i2 = MailboxRecord(accountId: account2.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            i2 = try i2.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return (i1.id!, a1.id!, i2.id!)
        }

        try database.dbWriter.write { db in
            var m1 = MessageRecord(mailboxId: inbox1, uid: 1, internalDate: Date())
            try m1.insert(db)
            var m2 = MessageRecord(mailboxId: archive1, uid: 1, internalDate: Date())
            try m2.insert(db) // archive is not inbox-role — must not count
            var m3 = MessageRecord(mailboxId: inbox2, uid: 1, internalDate: Date())
            try m3.insert(db)
            var m4 = MessageRecord(mailboxId: inbox2, uid: 2, internalDate: Date(), flagsRaw: MessageFlags.seen.rawValue)
            try m4.insert(db) // seen — must not count
        }

        let total = try database.dbWriter.read { db in
            try MessageQuery.unifiedInboxUnreadCount(accountIds: [account1.id, account2.id], db: db)
        }
        #expect(total == 2)
    }
}
