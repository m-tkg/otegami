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

    // MARK: - E9 ピン留め: pinned threads sort first

    @Test("request(mailboxId:) sorts a pinned thread ahead of a newer unpinned one")
    func requestSortsPinnedThreadFirst() throws {
        let (database, accountId, inboxId, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (older, newer) = try database.dbWriter.write { db -> (Int64, Int64) in
            let older = try insertThread(accountId: accountId, mailboxId: inboxId, uid: 1, date: base, db: db)
            let newer = try insertThread(accountId: accountId, mailboxId: inboxId, uid: 2, date: base.addingTimeInterval(3600), db: db)
            // Pin every message in the older thread (mirrors `MessageListView
            // .applyPinState`) and recompute the thread's OR-aggregate.
            var messages = try MessageRecord.filter(Column("threadId") == older).fetchAll(db)
            for index in messages.indices {
                messages[index].isPinnedLocal = true
                try messages[index].update(db)
            }
            try ThreadAssigner.recomputeAggregates(threadId: older, db: db)
            return (older, newer)
        }

        let threadIds = try database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: inboxId).fetchAll(db).map(\.id)
        }
        #expect(threadIds == [older, newer], "Expected the pinned (older) thread to sort ahead of the newer unpinned one")
    }

    // MARK: - B3 フラット表示

    @Test("flatSummaries returns one row per message, not per thread")
    func flatSummariesReturnsOneRowPerMessage() throws {
        let (database, accountId, inboxId, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 3)
            try thread.insert(db)
            for uid in 1...3 {
                var message = MessageRecord(
                    mailboxId: inboxId, uid: Int64(uid),
                    date: base.addingTimeInterval(Double(uid) * 60), internalDate: base.addingTimeInterval(Double(uid) * 60),
                    threadId: thread.id
                )
                try message.insert(db)
            }
        }

        let flat = try database.dbWriter.read { db in
            try ThreadQuery.flatSummaries(mailboxId: inboxId, accountId: accountId, db: db)
        }
        #expect(flat.count == 3, "Expected 3 separate rows for a 3-message thread in flat mode")
        // Each synthetic summary should report the real thread id (for
        // actions) while still being individually addressable/unique (for
        // `List` row identity) — see `ThreadSummary.init(flatMessage:accountId:)`.
        #expect(Set(flat.map(\.id)).count == 3, "Expected each flat row to have a unique List identity")
        #expect(Set(flat.map(\.thread.accountId)) == [accountId])
    }

    @Test("flatSummaries sorts a pinned message ahead of a newer unpinned one")
    func flatSummariesSortsPinnedMessageFirst() throws {
        let (database, accountId, inboxId, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (olderMessageId, _) = try database.dbWriter.write { db -> (Int64, Int64) in
            var olderThread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 1)
            try olderThread.insert(db)
            var older = MessageRecord(mailboxId: inboxId, uid: 1, date: base, internalDate: base, threadId: olderThread.id, isPinnedLocal: true)
            try older.insert(db)

            var newerThread = ThreadRecord(accountId: accountId, lastMessageDate: base.addingTimeInterval(3600), messageCount: 1)
            try newerThread.insert(db)
            var newer = MessageRecord(
                mailboxId: inboxId, uid: 2, date: base.addingTimeInterval(3600), internalDate: base.addingTimeInterval(3600), threadId: newerThread.id
            )
            try newer.insert(db)
            return (older.id!, newer.id!)
        }

        let flat = try database.dbWriter.read { db in
            try ThreadQuery.flatSummaries(mailboxId: inboxId, accountId: accountId, db: db)
        }
        #expect(flat.first?.latestMessage?.id == olderMessageId, "Expected the pinned (older) message to sort first")
    }

    @Test("unifiedInboxFlatSummaries interleaves messages across accounts' inbox mailboxes")
    func unifiedInboxFlatSummariesInterleavesAccounts() throws {
        let (database, accountIdA, inboxIdA, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let accountB = AccountRecord(
            displayName: "Test B", email: "b@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "b@x.test"
        )
        let inboxIdB = try database.dbWriter.write { db -> Int64 in
            try accountB.insert(db)
            var inbox = MailboxRecord(accountId: accountB.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return inbox.id!
        }

        try database.dbWriter.write { db in
            var threadA = ThreadRecord(accountId: accountIdA, lastMessageDate: base, messageCount: 1)
            try threadA.insert(db)
            var messageA = MessageRecord(mailboxId: inboxIdA, uid: 1, date: base, internalDate: base, threadId: threadA.id)
            try messageA.insert(db)

            var threadB = ThreadRecord(accountId: accountB.id, lastMessageDate: base.addingTimeInterval(60), messageCount: 1)
            try threadB.insert(db)
            var messageB = MessageRecord(mailboxId: inboxIdB, uid: 1, date: base.addingTimeInterval(60), internalDate: base.addingTimeInterval(60), threadId: threadB.id)
            try messageB.insert(db)
        }

        let flat = try database.dbWriter.read { db in
            try ThreadQuery.unifiedInboxFlatSummaries(accountIds: [accountIdA, accountB.id], db: db)
        }
        #expect(flat.count == 2)
        #expect(flat.map(\.thread.accountId) == [accountB.id, accountIdA], "Expected newest-first interleaving across accounts")
    }

    // MARK: - Mute (新画面構成: メール本文画面「…」メニューの「スレッドをミュート」)

    @Test("setMuted toggles isMuted and is idempotent")
    func setMutedTogglesIsMuted() throws {
        let (database, accountId, inboxId, _) = try makeDatabase()
        let threadId = try database.dbWriter.write { db in
            try insertThread(accountId: accountId, mailboxId: inboxId, uid: 1, date: Date(), db: db)
        }

        try database.dbWriter.write { db in try ThreadQuery.setMuted(threadId: threadId, muted: true, db: db) }
        var thread = try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) }
        #expect(thread?.isMuted == true)

        // Idempotent: setting the same value again is a harmless no-op.
        try database.dbWriter.write { db in try ThreadQuery.setMuted(threadId: threadId, muted: true, db: db) }
        thread = try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) }
        #expect(thread?.isMuted == true)

        try database.dbWriter.write { db in try ThreadQuery.setMuted(threadId: threadId, muted: false, db: db) }
        thread = try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) }
        #expect(thread?.isMuted == false)
    }

    @Test("setMuted on a nonexistent thread id is a no-op, not an error")
    func setMutedOnMissingThreadIsNoOp() throws {
        let (database, _, _, _) = try makeDatabase()
        #expect(throws: Never.self) {
            try database.dbWriter.write { db in try ThreadQuery.setMuted(threadId: 999_999, muted: true, db: db) }
        }
    }
}
