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

    /// メールボックス単位の非表示: this only matters in practice if the
    /// inbox-role mailbox itself is hidden (`MailboxRecord.isHidden`'s doc
    /// comment) — a non-inbox mailbox like Gmail's "すべてのメール" was
    /// already excluded by `unifiedInboxScopesToInboxRole` above.
    @Test("unifiedInboxRequest excludes a hidden inbox-role mailbox's threads")
    func unifiedInboxExcludesHiddenMailbox() throws {
        let (database, accountId, inboxId, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try database.dbWriter.write { db in
            try insertThread(accountId: accountId, mailboxId: inboxId, uid: 1, date: base, db: db)
        }

        try database.dbWriter.write { db in
            try MailboxQuery.setHidden(mailboxId: inboxId, hidden: true, db: db)
        }

        let threadIds = try database.dbWriter.read { db in
            try ThreadQuery.unifiedInboxRequest(accountIds: [accountId]).fetchAll(db).map(\.id)
        }
        #expect(threadIds.isEmpty)
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

    // MARK: - 未読のみ表示 (ヘッダのトグル)

    /// Inserts one thread with one message in `mailboxId`, then recomputes
    /// the thread's `unreadCount` aggregate from that message's flags —
    /// unlike `insertThread` above (which leaves `unreadCount` at its
    /// `ThreadRecord` default of `0` regardless of the message's own
    /// flags), the unread-filter tests need that aggregate to actually
    /// reflect what was inserted, since `request(unreadOnly:)` reads
    /// `thread.unreadCount` directly rather than joining messages.
    @discardableResult
    private func insertThread(accountId: String, mailboxId: Int64, uid: Int64, date: Date, seen: Bool, db: Database) throws -> Int64 {
        var thread = ThreadRecord(accountId: accountId, lastMessageDate: date, messageCount: 1)
        try thread.insert(db)
        var message = MessageRecord(
            mailboxId: mailboxId, uid: uid, date: date, internalDate: date,
            flagsRaw: seen ? MessageFlags.seen.rawValue : 0, threadId: thread.id
        )
        try message.insert(db)
        try ThreadAssigner.recomputeAggregates(threadId: thread.id!, db: db)
        return thread.id!
    }

    @Test("request(unreadOnly: true) only returns threads with at least one unread message")
    func requestUnreadOnlyFiltersReadThreads() throws {
        let (database, accountId, inboxId, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (unread, _) = try database.dbWriter.write { db -> (Int64, Int64) in
            let unread = try insertThread(accountId: accountId, mailboxId: inboxId, uid: 1, date: base, seen: false, db: db)
            let read = try insertThread(accountId: accountId, mailboxId: inboxId, uid: 2, date: base.addingTimeInterval(3600), seen: true, db: db)
            return (unread, read)
        }

        let threadIds = try database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: inboxId, unreadOnly: true).fetchAll(db).map(\.id)
        }
        #expect(threadIds == [unread])
    }

    @Test("unifiedInboxRequest(unreadOnly: true) combines with the account scope, not just the unread scope")
    func unifiedInboxRequestUnreadOnlyCombinesWithAccountFilter() throws {
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

        // Account A: one unread thread. Account B: one unread thread too,
        // but scoped out by only passing account A's id below — proves the
        // unread filter doesn't accidentally widen the account scope.
        let (unreadA, _) = try database.dbWriter.write { db -> (Int64, Int64) in
            let unreadA = try insertThread(accountId: accountIdA, mailboxId: inboxIdA, uid: 1, date: base, seen: false, db: db)
            let readA = try insertThread(accountId: accountIdA, mailboxId: inboxIdA, uid: 2, date: base.addingTimeInterval(60), seen: true, db: db)
            _ = try insertThread(accountId: accountB.id, mailboxId: inboxIdB, uid: 1, date: base.addingTimeInterval(120), seen: false, db: db)
            return (unreadA, readA)
        }

        let threadIds = try database.dbWriter.read { db in
            try ThreadQuery.unifiedInboxRequest(accountIds: [accountIdA], unreadOnly: true).fetchAll(db).map(\.id)
        }
        #expect(threadIds == [unreadA], "Expected only account A's unread thread, not account B's or account A's read thread")
    }

    // MARK: - Task #142: フラグ付きのみ表示

    @Test("request(pinnedOnly: true) only returns pinned threads")
    func requestPinnedOnlyFiltersUnpinnedThreads() throws {
        let (database, accountId, inboxId, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (pinned, _) = try database.dbWriter.write { db -> (Int64, Int64) in
            let pinned = try insertThread(accountId: accountId, mailboxId: inboxId, uid: 1, date: base, db: db)
            let unpinned = try insertThread(accountId: accountId, mailboxId: inboxId, uid: 2, date: base.addingTimeInterval(3600), db: db)
            var messages = try MessageRecord.filter(Column("threadId") == pinned).fetchAll(db)
            for index in messages.indices {
                messages[index].isPinnedLocal = true
                try messages[index].update(db)
            }
            try ThreadAssigner.recomputeAggregates(threadId: pinned, db: db)
            return (pinned, unpinned)
        }

        let threadIds = try database.dbWriter.read { db in
            try ThreadQuery.request(mailboxId: inboxId, pinnedOnly: true).fetchAll(db).map(\.id)
        }
        #expect(threadIds == [pinned])
    }

    @Test("unifiedInboxRequest(unreadOnly: true, pinnedOnly: true) ANDs both filters together")
    func unifiedInboxRequestCombinesUnreadAndPinnedFilters() throws {
        let (database, accountId, inboxId, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let (unreadAndPinned, _, _) = try database.dbWriter.write { db -> (Int64, Int64, Int64) in
            // Unread + pinned: should survive both filters.
            var unreadPinnedThread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 1)
            try unreadPinnedThread.insert(db)
            var unreadPinnedMessage = MessageRecord(mailboxId: inboxId, uid: 1, date: base, internalDate: base, threadId: unreadPinnedThread.id, isPinnedLocal: true)
            try unreadPinnedMessage.insert(db)
            try ThreadAssigner.recomputeAggregates(threadId: unreadPinnedThread.id!, db: db)

            // Read + pinned: excluded by unreadOnly even though pinned.
            var readPinnedThread = ThreadRecord(accountId: accountId, lastMessageDate: base.addingTimeInterval(60), messageCount: 1)
            try readPinnedThread.insert(db)
            var readPinnedMessage = MessageRecord(
                mailboxId: inboxId, uid: 2, date: base.addingTimeInterval(60), internalDate: base.addingTimeInterval(60),
                flagsRaw: MessageFlags.seen.rawValue, threadId: readPinnedThread.id, isPinnedLocal: true
            )
            try readPinnedMessage.insert(db)
            try ThreadAssigner.recomputeAggregates(threadId: readPinnedThread.id!, db: db)

            // Unread + unpinned: excluded by pinnedOnly even though unread.
            var unreadUnpinnedThread = ThreadRecord(accountId: accountId, lastMessageDate: base.addingTimeInterval(120), messageCount: 1)
            try unreadUnpinnedThread.insert(db)
            var unreadUnpinnedMessage = MessageRecord(mailboxId: inboxId, uid: 3, date: base.addingTimeInterval(120), internalDate: base.addingTimeInterval(120), threadId: unreadUnpinnedThread.id)
            try unreadUnpinnedMessage.insert(db)
            try ThreadAssigner.recomputeAggregates(threadId: unreadUnpinnedThread.id!, db: db)

            return (unreadPinnedThread.id!, readPinnedThread.id!, unreadUnpinnedThread.id!)
        }

        let threadIds = try database.dbWriter.read { db in
            try ThreadQuery.unifiedInboxRequest(accountIds: [accountId], unreadOnly: true, pinnedOnly: true).fetchAll(db).map(\.id)
        }
        #expect(threadIds == [unreadAndPinned], "Expected only the thread that's both unread and pinned")
    }

    @Test("flatSummaries(pinnedOnly: true) filters by the message's own isPinnedLocal")
    func flatSummariesPinnedOnlyFiltersUnpinnedMessages() throws {
        let (database, accountId, inboxId, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let pinnedMessageId = try database.dbWriter.write { db -> Int64 in
            var pinnedThread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 1)
            try pinnedThread.insert(db)
            var pinned = MessageRecord(mailboxId: inboxId, uid: 1, date: base, internalDate: base, threadId: pinnedThread.id, isPinnedLocal: true)
            try pinned.insert(db)

            var unpinnedThread = ThreadRecord(accountId: accountId, lastMessageDate: base.addingTimeInterval(60), messageCount: 1)
            try unpinnedThread.insert(db)
            var unpinned = MessageRecord(mailboxId: inboxId, uid: 2, date: base.addingTimeInterval(60), internalDate: base.addingTimeInterval(60), threadId: unpinnedThread.id)
            try unpinned.insert(db)
            return pinned.id!
        }

        let flat = try database.dbWriter.read { db in
            try ThreadQuery.flatSummaries(mailboxId: inboxId, accountId: accountId, pinnedOnly: true, db: db)
        }
        #expect(flat.map(\.latestMessage?.id) == [pinnedMessageId])
    }

    @Test("unifiedInboxFlatSummaries(pinnedOnly: true) filters by the message's own isPinnedLocal")
    func unifiedInboxFlatSummariesPinnedOnlyFiltersUnpinnedMessages() throws {
        let (database, accountId, inboxId, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let pinnedMessageId = try database.dbWriter.write { db -> Int64 in
            var pinnedThread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 1)
            try pinnedThread.insert(db)
            var pinned = MessageRecord(mailboxId: inboxId, uid: 1, date: base, internalDate: base, threadId: pinnedThread.id, isPinnedLocal: true)
            try pinned.insert(db)

            var unpinnedThread = ThreadRecord(accountId: accountId, lastMessageDate: base.addingTimeInterval(60), messageCount: 1)
            try unpinnedThread.insert(db)
            var unpinned = MessageRecord(mailboxId: inboxId, uid: 2, date: base.addingTimeInterval(60), internalDate: base.addingTimeInterval(60), threadId: unpinnedThread.id)
            try unpinned.insert(db)
            return pinned.id!
        }

        let flat = try database.dbWriter.read { db in
            try ThreadQuery.unifiedInboxFlatSummaries(accountIds: [accountId], pinnedOnly: true, db: db)
        }
        #expect(flat.map(\.latestMessage?.id) == [pinnedMessageId])
    }

    @Test("flatSummaries(unreadOnly: true) filters by the message's own \\Seen flag")
    func flatSummariesUnreadOnlyFiltersReadMessages() throws {
        let (database, accountId, inboxId, _) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let unreadMessageId = try database.dbWriter.write { db -> Int64 in
            var unreadThread = ThreadRecord(accountId: accountId, lastMessageDate: base, messageCount: 1)
            try unreadThread.insert(db)
            var unread = MessageRecord(mailboxId: inboxId, uid: 1, date: base, internalDate: base, threadId: unreadThread.id)
            try unread.insert(db)

            var readThread = ThreadRecord(accountId: accountId, lastMessageDate: base.addingTimeInterval(60), messageCount: 1)
            try readThread.insert(db)
            var read = MessageRecord(
                mailboxId: inboxId, uid: 2, date: base.addingTimeInterval(60), internalDate: base.addingTimeInterval(60),
                flagsRaw: MessageFlags.seen.rawValue, threadId: readThread.id
            )
            try read.insert(db)
            return unread.id!
        }

        let flat = try database.dbWriter.read { db in
            try ThreadQuery.flatSummaries(mailboxId: inboxId, accountId: accountId, unreadOnly: true, db: db)
        }
        #expect(flat.map(\.latestMessage?.id) == [unreadMessageId])
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

    // MARK: - Task #150 repro: a thread spanning multiple mailboxes must not duplicate

    @Test("unifiedInboxRequest doesn't duplicate a thread that has messages in two different mailboxes")
    func unifiedInboxRequestDoesNotDuplicateThreadSpanningMailboxes() throws {
        let (database, accountId, inboxId, archiveId) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base.addingTimeInterval(60), messageCount: 2)
            try thread.insert(db)
            var inboxMessage = MessageRecord(mailboxId: inboxId, uid: 1, date: base, internalDate: base, threadId: thread.id)
            try inboxMessage.insert(db)
            var archiveMessage = MessageRecord(mailboxId: archiveId, uid: 1, date: base.addingTimeInterval(60), internalDate: base.addingTimeInterval(60), threadId: thread.id)
            try archiveMessage.insert(db)
            return thread.id!
        }

        for pinnedOnly in [false, true] {
            let threadIds = try database.dbWriter.read { db in
                try ThreadQuery.unifiedInboxRequest(accountIds: [accountId], role: .inbox, pinnedOnly: pinnedOnly).fetchAll(db).map(\.id)
            }
            if pinnedOnly {
                #expect(threadIds.isEmpty, "pinnedOnly with no pinned messages should exclude the thread")
            } else {
                #expect(threadIds == [threadId], "Expected the thread exactly once, not duplicated across its two mailboxes")
            }
        }

        let allRoleIds = try database.dbWriter.read { db in
            try ThreadQuery.unifiedInboxRequest(accountIds: [accountId], role: .all).fetchAll(db).map(\.id)
        }
        #expect(allRoleIds == [threadId], "role .all (non-Gmail any-mailbox scope) must still return the thread once, not once per mailbox it has a message in")

        let archiveRoleIds = try database.dbWriter.read { db in
            try ThreadQuery.unifiedInboxRequest(accountIds: [accountId], role: .archive).fetchAll(db).map(\.id)
        }
        #expect(archiveRoleIds == [threadId])
    }

    @Test("summaries(forThreads:) attaches exactly one summary per thread even when it spans mailboxes")
    func summariesDoNotDuplicateThreadSpanningMailboxes() throws {
        let (database, accountId, inboxId, archiveId) = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadId = try database.dbWriter.write { db -> Int64 in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: base.addingTimeInterval(60), messageCount: 2)
            try thread.insert(db)
            var inboxMessage = MessageRecord(mailboxId: inboxId, uid: 1, date: base, internalDate: base, threadId: thread.id)
            try inboxMessage.insert(db)
            var archiveMessage = MessageRecord(mailboxId: archiveId, uid: 1, date: base.addingTimeInterval(60), internalDate: base.addingTimeInterval(60), threadId: thread.id)
            try archiveMessage.insert(db)
            return thread.id!
        }

        let summaries = try database.dbWriter.read { db in
            try ThreadQuery.summaries(
                forThreads: ThreadQuery.unifiedInboxRequest(accountIds: [accountId], role: .all).fetchAll(db), db: db
            )
        }
        #expect(summaries.map(\.id) == [threadId])
    }

    @Test("setMuted on a nonexistent thread id is a no-op, not an error")
    func setMutedOnMissingThreadIsNoOp() throws {
        let (database, _, _, _) = try makeDatabase()
        #expect(throws: Never.self) {
            try database.dbWriter.write { db in try ThreadQuery.setMuted(threadId: 999_999, muted: true, db: db) }
        }
    }
}
