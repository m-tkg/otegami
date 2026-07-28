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

    @Test("unifiedInboxUnreadCount excludes a hidden inbox-role mailbox")
    func unifiedInboxUnreadCountExcludesHiddenMailbox() throws {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let inboxId = try database.dbWriter.write { db -> Int64 in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return inbox.id!
        }
        try database.dbWriter.write { db in
            var unread = MessageRecord(mailboxId: inboxId, uid: 1, internalDate: Date())
            try unread.insert(db)
        }

        let beforeHiding = try database.dbWriter.read { db in
            try MessageQuery.unifiedInboxUnreadCount(accountIds: [account.id], db: db)
        }
        #expect(beforeHiding == 1)

        try database.dbWriter.write { db in
            try MailboxQuery.setHidden(mailboxId: inboxId, hidden: true, db: db)
        }

        let afterHiding = try database.dbWriter.read { db in
            try MessageQuery.unifiedInboxUnreadCount(accountIds: [account.id], db: db)
        }
        #expect(afterHiding == 0)
    }

    // MARK: - Background body prefetch (launch/foreground/post-sync)

    @Test("unfetchedUnifiedInboxCandidates returns only notFetched messages across accounts' inboxes, newest first, up to limit")
    func unfetchedUnifiedInboxCandidatesFiltersAndOrders() throws {
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

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            // account1 inbox: notFetched, oldest of the notFetched set.
            var m1 = MessageRecord(mailboxId: inbox1, uid: 1, subject: "a1-notfetched", internalDate: base)
            try m1.insert(db)
            // account1 inbox: already fetched — must be excluded.
            var m2 = MessageRecord(mailboxId: inbox1, uid: 2, subject: "a1-fetched", internalDate: base.addingTimeInterval(7200), bodyState: .fetched)
            try m2.insert(db)
            // account1 archive (non-inbox role): must be excluded regardless of bodyState.
            var m3 = MessageRecord(mailboxId: archive1, uid: 1, subject: "a1-archive", internalDate: base.addingTimeInterval(9000))
            try m3.insert(db)
            // account2 inbox: notFetched, newest overall.
            var m4 = MessageRecord(mailboxId: inbox2, uid: 1, subject: "a2-notfetched", internalDate: base.addingTimeInterval(3600))
            try m4.insert(db)
        }

        let since = base.addingTimeInterval(-1)
        let candidates = try database.dbWriter.read { db in
            try MessageQuery.unfetchedUnifiedInboxCandidates(accountIds: [account1.id, account2.id], since: since, limit: 10, db: db)
        }
        #expect(candidates.map(\.message.subject) == ["a2-notfetched", "a1-notfetched"])
        #expect(candidates.allSatisfy { $0.message.bodyState == .notFetched })
        #expect(Set(candidates.map(\.accountId)) == [account1.id, account2.id])
        #expect(candidates.first { $0.accountId == account1.id }?.mailboxPath == "INBOX")

        let limited = try database.dbWriter.read { db in
            try MessageQuery.unfetchedUnifiedInboxCandidates(accountIds: [account1.id, account2.id], since: since, limit: 1, db: db)
        }
        #expect(limited.map(\.message.subject) == ["a2-notfetched"])
    }

    @Test("unfetchedUnifiedInboxCandidates excludes notFetched messages older than the since cutoff")
    func unfetchedUnifiedInboxCandidatesRespectsSinceCutoff() throws {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "A1", email: "a1@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "a1@x.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let inbox = try database.dbWriter.write { db -> Int64 in
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return mailbox.id!
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)
        try database.dbWriter.write { db in
            // Just inside the 3-day window: included.
            var recent = MessageRecord(mailboxId: inbox, uid: 1, subject: "recent", internalDate: threeDaysAgo.addingTimeInterval(3600))
            try recent.insert(db)
            // Just outside the 3-day window: excluded even though notFetched.
            var stale = MessageRecord(mailboxId: inbox, uid: 2, subject: "stale", internalDate: threeDaysAgo.addingTimeInterval(-3600))
            try stale.insert(db)
        }

        let candidates = try database.dbWriter.read { db in
            try MessageQuery.unfetchedUnifiedInboxCandidates(accountIds: [account.id], since: threeDaysAgo, limit: 200, db: db)
        }
        #expect(candidates.map(\.message.subject) == ["recent"])
    }
}

@Suite("MailboxQuery")
struct MailboxQueryTests {
    private func makeDatabase() throws -> (database: AppDatabase, accountId: String) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        return (database, account.id)
    }

    @Test("request(accountId:includeHidden: false) excludes hidden mailboxes; the default includes everything")
    func includeHiddenFiltering() throws {
        let (database, accountId) = try makeDatabase()
        let (inboxId, allMailId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var inbox = MailboxRecord(accountId: accountId, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var allMail = MailboxRecord(accountId: accountId, path: "[Gmail]/All Mail", displayPath: "[Gmail]/All Mail", role: .all)
            allMail = try allMail.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return (inbox.id!, allMail.id!)
        }
        try database.dbWriter.write { db in
            try MailboxQuery.setHidden(mailboxId: allMailId, hidden: true, db: db)
        }

        let visibleOnly = try database.dbWriter.read { db in
            try MailboxQuery.request(accountId: accountId, includeHidden: false).fetchAll(db).map(\.id)
        }
        #expect(visibleOnly == [inboxId])

        let everything = try database.dbWriter.read { db in
            try MailboxQuery.request(accountId: accountId).fetchAll(db).compactMap(\.id).sorted()
        }
        #expect(everything == [inboxId, allMailId].sorted())
    }

    @Test("setHidden toggles isHidden and is idempotent")
    func setHiddenToggles() throws {
        let (database, accountId) = try makeDatabase()
        let mailboxId = try database.dbWriter.write { db -> Int64 in
            var mailbox = MailboxRecord(accountId: accountId, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return mailbox.id!
        }

        try database.dbWriter.write { db in try MailboxQuery.setHidden(mailboxId: mailboxId, hidden: true, db: db) }
        var mailbox = try database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: mailboxId) }
        #expect(mailbox?.isHidden == true)

        // Idempotent: setting the same value again doesn't throw or flip anything unexpected.
        try database.dbWriter.write { db in try MailboxQuery.setHidden(mailboxId: mailboxId, hidden: true, db: db) }
        mailbox = try database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: mailboxId) }
        #expect(mailbox?.isHidden == true)

        try database.dbWriter.write { db in try MailboxQuery.setHidden(mailboxId: mailboxId, hidden: false, db: db) }
        mailbox = try database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: mailboxId) }
        #expect(mailbox?.isHidden == false)
    }
}
