import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// Task #92 (アカウントダイジェスト画面): covers `AccountDigestQuery`'s
/// per-account counting/ordering/scoping — the data `AccountDigestView`
/// renders, exercised here with no SwiftUI host (mirrors
/// `ThreadQueryTests`'s own setup helpers).
@Suite("AccountDigestQuery")
struct AccountDigestQueryTests {
    private func makeDatabase() throws -> (database: AppDatabase, accountId: String, inboxId: Int64, archiveId: Int64) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@example.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@example.test"
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

    /// One thread with one message in `mailboxId`, dated `date` —
    /// `unreadCount` is set directly on the synthetic `ThreadRecord` (not
    /// derived from a real `ThreadAssigner.recomputeAggregates` pass),
    /// matching `ThreadSummary.init(flatMessage:accountId:)`'s own
    /// "construct the aggregate directly" convention for tests/synthetic
    /// rows at this scale.
    @discardableResult
    private func insertThread(accountId: String, mailboxId: Int64, uid: Int64, date: Date, subject: String, unread: Bool, db: Database) throws -> Int64 {
        var thread = ThreadRecord(accountId: accountId, lastMessageDate: date, messageCount: 1, unreadCount: unread ? 1 : 0)
        try thread.insert(db)
        var message = MessageRecord(mailboxId: mailboxId, uid: uid, subject: subject, date: date, internalDate: date, threadId: thread.id)
        if !unread { message.flagsRaw |= MessageQuery.seenFlagBit }
        try message.insert(db)
        return thread.id!
    }

    @Test("digests(accountIds:) reports total/unread counts scoped to one account's role")
    func digestsReportsCounts() throws {
        let (database, accountId, inboxId, archiveId) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            try insertThread(accountId: accountId, mailboxId: inboxId, uid: 1, date: base, subject: "A", unread: true, db: db)
            try insertThread(accountId: accountId, mailboxId: inboxId, uid: 2, date: base.addingTimeInterval(60), subject: "B", unread: false, db: db)
            // Archive-role mail shouldn't count toward the inbox digest.
            try insertThread(accountId: accountId, mailboxId: archiveId, uid: 1, date: base.addingTimeInterval(120), subject: "C", unread: true, db: db)
        }

        let digests = try database.dbWriter.read { db in
            try AccountDigestQuery.digests(accountIds: [accountId], db: db)
        }

        #expect(digests.count == 1)
        #expect(digests[0].accountId == accountId)
        #expect(digests[0].totalCount == 2)
        #expect(digests[0].unreadCount == 1)
    }

    @Test("digests(accountIds:) still includes an account with zero matching threads")
    func digestsIncludesEmptyAccount() throws {
        let (database, accountId, _, _) = try makeDatabase()

        let digests = try database.dbWriter.read { db in
            try AccountDigestQuery.digests(accountIds: [accountId], db: db)
        }

        #expect(digests.count == 1)
        #expect(digests[0].totalCount == 0)
        #expect(digests[0].unreadCount == 0)
        #expect(digests[0].recentSummaries.isEmpty)
    }

    @Test("digests(accountIds:recentLimit:) caps recentSummaries but not totalCount")
    func digestsCapsRecentSummariesOnly() throws {
        let (database, accountId, inboxId, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let ids = try database.dbWriter.write { db -> [Int64] in
            try (0..<5).map { i in
                try insertThread(accountId: accountId, mailboxId: inboxId, uid: Int64(i), date: base.addingTimeInterval(Double(i) * 60), subject: "S\(i)", unread: false, db: db)
            }
        }
        let newestTwo = Array(ids.reversed().prefix(2))

        let digests = try database.dbWriter.read { db in
            try AccountDigestQuery.digests(accountIds: [accountId], recentLimit: 2, db: db)
        }

        #expect(digests[0].totalCount == 5)
        #expect(digests[0].recentSummaries.map(\.thread.id) == newestTwo)
    }

    /// Task #137 (実機報告「『すべてのアーカイブ』のダイジェストで、各行の
    /// バッジがボックス無関係の値」): a single *thread* that spans two
    /// mailboxes of different roles — one message still unread in INBOX,
    /// one already-read message in Archive — matches
    /// `ThreadQuery.unifiedInboxRequest`'s own doc comment ("a thread can
    /// span mailboxes, e.g. Inbox + Sent"). Before the fix, `AccountDigest
    /// .unreadCount` summed `ThreadRecord.unreadCount` (a thread-wide
    /// aggregate that would count this thread's INBOX-side unread message
    /// even for the *archive* digest, since the thread also has a message
    /// in Archive and so qualifies for that scope's `totalCount`) — this
    /// pins the fixed, message-level/role-scoped behavior instead: the
    /// archive digest sees 0 unread (its own message is read), the inbox
    /// digest sees 1 (its own message is unread), even though both digests
    /// report the same thread in their `totalCount`.
    @Test("digests(accountIds:role:) scopes unreadCount to the role's own messages, not the whole thread")
    func digestsScopesUnreadCountToRole() throws {
        let (database, accountId, inboxId, archiveId) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 2, unreadCount: 1)
            try thread.insert(db)
            var inboxMessage = MessageRecord(mailboxId: inboxId, uid: 1, subject: "A", date: base, internalDate: base, threadId: thread.id)
            // Unread (no .seen bit) — still sitting in INBOX.
            try inboxMessage.insert(db)
            var archiveMessage = MessageRecord(mailboxId: archiveId, uid: 1, subject: "A", date: base.addingTimeInterval(60), internalDate: base.addingTimeInterval(60), threadId: thread.id)
            archiveMessage.flagsRaw |= MessageQuery.seenFlagBit // Already read in Archive.
            try archiveMessage.insert(db)
        }

        let archiveDigests = try database.dbWriter.read { db in
            try AccountDigestQuery.digests(accountIds: [accountId], role: .archive, db: db)
        }
        let inboxDigests = try database.dbWriter.read { db in
            try AccountDigestQuery.digests(accountIds: [accountId], role: .inbox, db: db)
        }

        #expect(archiveDigests[0].totalCount == 1)
        #expect(archiveDigests[0].unreadCount == 0)
        #expect(inboxDigests[0].totalCount == 1)
        #expect(inboxDigests[0].unreadCount == 1)
    }

    @Test("allSummaries(accountId:role:) returns every thread in scope, newest first")
    func allSummariesReturnsEveryThread() throws {
        let (database, accountId, inboxId, archiveId) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (t1, t2) = try database.dbWriter.write { db -> (Int64, Int64) in
            let t1 = try insertThread(accountId: accountId, mailboxId: inboxId, uid: 1, date: base, subject: "A", unread: false, db: db)
            let t2 = try insertThread(accountId: accountId, mailboxId: inboxId, uid: 2, date: base.addingTimeInterval(60), subject: "B", unread: false, db: db)
            try insertThread(accountId: accountId, mailboxId: archiveId, uid: 1, date: base.addingTimeInterval(120), subject: "C", unread: false, db: db)
            return (t1, t2)
        }

        let summaries = try database.dbWriter.read { db in
            try AccountDigestQuery.allSummaries(accountId: accountId, db: db)
        }

        #expect(summaries.map(\.thread.id) == [t2, t1])
    }
}
