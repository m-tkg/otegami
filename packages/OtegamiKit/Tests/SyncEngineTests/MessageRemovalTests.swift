import Foundation
import GRDB
import Testing
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// Regression coverage for 実機報告「アーカイブをした後、元に戻すをしても戻ってなさそう」—
/// see `MessageRemoval.undo(_:db:)`'s doc comment for the root cause (message
/// rows re-inserted before the thread row they reference, tripping
/// `message.threadId`'s foreign key whenever the removal had emptied, and so
/// deleted, the thread — i.e. every single-message thread, the common case).
/// `MessageListView` (the app target) only ever called this logic through a
/// SwiftUI host before it moved here, so none of this had automated coverage
/// prior to this file.
@Suite("MessageRemoval")
struct MessageRemovalTests {
    private func makeDatabase() throws -> (database: AppDatabase, accountId: String, inboxId: Int64) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@x.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@x.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        let inboxId = try database.dbWriter.write { db -> Int64 in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1)
            try inbox.insert(db)
            return inbox.id!
        }
        return (database, account.id, inboxId)
    }

    /// One thread with one message in `mailboxId`, dated `date` — a
    /// single-message thread, the case that reproduces the ordering bug
    /// (archiving/deleting its only message empties, and so deletes, the
    /// `thread` row).
    @discardableResult
    private func insertSingleMessageThread(
        accountId: String, mailboxId: Int64, uid: Int64, date: Date, db: Database
    ) throws -> (threadId: Int64, messageId: Int64) {
        var thread = ThreadRecord(accountId: accountId, lastMessageDate: date, messageCount: 1)
        try thread.insert(db)
        var message = MessageRecord(mailboxId: mailboxId, uid: uid, date: date, internalDate: date, threadId: thread.id)
        try message.insert(db)
        return (thread.id!, message.id!)
    }

    @Test("archive → undo restores a single-message thread, its message, and reappears in ThreadQuery")
    func undoRestoresSingleMessageThreadAfterArchive() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 1, date: date, db: db)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }
        let snapshot2 = try #require(snapshot)

        // The archive committed: the message (and, since it was the
        // thread's only message, the thread itself) are gone, and an
        // `archive` op is queued.
        let (messageAfterArchive, threadAfterArchive, threadsInMailboxAfterArchive, opCountAfterArchive) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try ThreadRecord.fetchOne(db, key: threadId),
                try ThreadQuery.request(mailboxId: inboxId).fetchAll(db).map(\.id),
                try OpQueueRecord.fetchCount(db)
            )
        }
        #expect(messageAfterArchive == nil)
        #expect(threadAfterArchive == nil)
        #expect(threadsInMailboxAfterArchive == [])
        #expect(opCountAfterArchive == 1)

        // Undo: before the fix, re-inserting `messageId` while `threadId`
        // didn't exist yet threw a foreign-key violation, the whole
        // transaction rolled back, and the outer `catch` swallowed it —
        // this thread would still be gone here.
        try database.dbWriter.write { db in
            try MessageRemoval.undo(snapshot2, db: db)
        }

        let (threadAfterUndo, messageAfterUndo, threadsInMailboxAfterUndo, opCountAfterUndo) = try database.dbWriter.read { db in
            (
                try ThreadRecord.fetchOne(db, key: threadId),
                try MessageRecord.fetchOne(db, key: messageId),
                try ThreadQuery.request(mailboxId: inboxId).fetchAll(db).map(\.id),
                try OpQueueRecord.fetchCount(db)
            )
        }
        #expect(threadAfterUndo != nil)
        #expect(messageAfterUndo != nil)
        // Back in the mailbox's thread query, exactly like it never left.
        #expect(threadsInMailboxAfterUndo == [threadId])
        // The pending archive op was cancelled outright rather than
        // replayed and then reversed — "無駄な往復をしない" for the common
        // case where undo beats the network to it.
        #expect(opCountAfterUndo == 0)
    }

    @Test("delete → undo restores a single-message thread the same way archive does")
    func undoRestoresSingleMessageThreadAfterDelete() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 7, date: date, db: db)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.delete, summary: summary, accountId: accountId, db: db)
        }
        let snapshot2 = try #require(snapshot)
        let threadAfterDelete = try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) }
        #expect(threadAfterDelete == nil)

        try database.dbWriter.write { db in try MessageRemoval.undo(snapshot2, db: db) }

        let (threadAfterUndo, messageAfterUndo) = try database.dbWriter.read { db in
            (try ThreadRecord.fetchOne(db, key: threadId), try MessageRecord.fetchOne(db, key: messageId))
        }
        #expect(threadAfterUndo != nil)
        #expect(messageAfterUndo != nil)
    }

    @Test("commit returns nil (no-op) once nothing is left to remove — e.g. undo already ran, or the thread vanished")
    func commitIsNilWhenThreadAlreadyGone() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 3, date: date, db: db)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }
        try database.dbWriter.write { db in
            _ = try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }

        // Re-committing against the same (now stale) summary — the thread
        // row is gone, so this must return nil rather than throw or
        // partially apply.
        let second = try database.dbWriter.write { db in
            try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }
        #expect(second == nil)
    }

    @Test("archiving a thread whose message already sits in the Archive mailbox skips it — and undo doesn't try to re-insert a still-present row")
    func archiveSkipsAlreadyArchivedMessageAndUndoStaysConsistent() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let archiveId = try database.dbWriter.write { db -> Int64 in
            var archive = MailboxRecord(accountId: accountId, path: "Archive", displayPath: "Archive", role: .archive, uidValidity: 1)
            try archive.insert(db)
            return archive.id!
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        // A two-message thread: one already-archived message (must be left
        // alone) plus one still-in-inbox message (the one this archive
        // actually acts on).
        let (threadId, inboxMessageId, archivedMessageId) = try database.dbWriter.write { db -> (Int64, Int64, Int64) in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: date, messageCount: 2)
            try thread.insert(db)
            var inboxMessage = MessageRecord(mailboxId: inboxId, uid: 1, date: date, internalDate: date, threadId: thread.id)
            try inboxMessage.insert(db)
            var archivedMessage = MessageRecord(
                mailboxId: archiveId, uid: 1, date: date.addingTimeInterval(-60), internalDate: date.addingTimeInterval(-60), threadId: thread.id
            )
            try archivedMessage.insert(db)
            return (thread.id!, inboxMessage.id!, archivedMessage.id!)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(thread: try ThreadRecord.fetchOne(db, key: threadId)!, latestMessage: try MessageRecord.fetchOne(db, key: inboxMessageId))
        }

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }
        let snapshot2 = try #require(snapshot)
        // Only the inbox copy was removed; the already-archived one is
        // untouched and must not be part of the undo snapshot (re-inserting
        // it would collide with its still-present primary key).
        #expect(snapshot2.messages.map(\.id) == [inboxMessageId])

        let (messageAfterArchive, archivedMessageStillThere, threadAfterArchive) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: inboxMessageId),
                try MessageRecord.fetchOne(db, key: archivedMessageId),
                try ThreadRecord.fetchOne(db, key: threadId)
            )
        }
        #expect(messageAfterArchive == nil)
        #expect(archivedMessageStillThere != nil)
        #expect(threadAfterArchive != nil) // thread survives: one message left

        // Undo must not throw (no duplicate-primary-key insert of the
        // still-present archived message) and must bring the inbox copy back.
        try database.dbWriter.write { db in try MessageRemoval.undo(snapshot2, db: db) }
        let (messageAfterUndo, threadAfterUndo) = try database.dbWriter.read { db in
            (try MessageRecord.fetchOne(db, key: inboxMessageId), try ThreadRecord.fetchOne(db, key: threadId))
        }
        #expect(messageAfterUndo != nil)
        #expect(threadAfterUndo?.messageCount == 2)
    }

    @Test("undoing after the op already replayed is a no-op on the opQueue but still restores locally")
    func undoAfterOpAlreadyReplayedStillRestoresLocally() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 9, date: date, db: db)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(thread: try ThreadRecord.fetchOne(db, key: threadId)!, latestMessage: try MessageRecord.fetchOne(db, key: messageId))
        }
        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }
        let snapshot2 = try #require(snapshot)

        // Simulate the op already having replayed to the server (e.g. the
        // account's IDLE loop won the race) — its opQueue row is gone
        // before undo runs.
        try database.dbWriter.write { db in
            try OpQueueRecord.deleteAll(db, keys: snapshot2.opQueueIds)
        }

        // Undo must not throw just because those rows are already gone,
        // and the local restore must still apply.
        try database.dbWriter.write { db in try MessageRemoval.undo(snapshot2, db: db) }
        let (threadAfterUndo, messageAfterUndo) = try database.dbWriter.read { db in
            (try ThreadRecord.fetchOne(db, key: threadId), try MessageRecord.fetchOne(db, key: messageId))
        }
        #expect(threadAfterUndo != nil)
        #expect(messageAfterUndo != nil)
    }

    // MARK: unarchive (Task #87, 1)

    @Test("unarchive → undo restores a single-message thread the same way archive does, and enqueues an unarchive op")
    func undoRestoresSingleMessageThreadAfterUnarchive() throws {
        let (database, accountId, _) = try makeDatabase()
        let archiveId = try database.dbWriter.write { db -> Int64 in
            var archive = MailboxRecord(accountId: accountId, path: "Archive", displayPath: "Archive", role: .archive, uidValidity: 1)
            try archive.insert(db)
            return archive.id!
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertSingleMessageThread(accountId: accountId, mailboxId: archiveId, uid: 4, date: date, db: db)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.unarchive, summary: summary, accountId: accountId, db: db)
        }
        let snapshot2 = try #require(snapshot)

        let (messageAfterUnarchive, threadAfterUnarchive, opCountAfterUnarchive, opKindAfterUnarchive) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try ThreadRecord.fetchOne(db, key: threadId),
                try OpQueueRecord.fetchCount(db),
                try OpQueueRecord.fetchOne(db)?.kind
            )
        }
        #expect(messageAfterUnarchive == nil)
        #expect(threadAfterUnarchive == nil)
        #expect(opCountAfterUnarchive == 1)
        #expect(opKindAfterUnarchive == OpQueueKind.unarchive.rawValue)

        try database.dbWriter.write { db in try MessageRemoval.undo(snapshot2, db: db) }

        let (threadAfterUndo, messageAfterUndo, opCountAfterUndo) = try database.dbWriter.read { db in
            (
                try ThreadRecord.fetchOne(db, key: threadId),
                try MessageRecord.fetchOne(db, key: messageId),
                try OpQueueRecord.fetchCount(db)
            )
        }
        #expect(threadAfterUndo != nil)
        #expect(messageAfterUndo != nil)
        #expect(opCountAfterUndo == 0)
    }

    @Test("unarchiving a Gmail account's All Mail-labeled message is treated as archived (no dedicated Archive role to check)")
    func unarchiveTreatsGmailAllMailAsArchived() throws {
        let database = try AppDatabase.makeInMemory()
        let gmailAccount = AccountRecord(
            displayName: "Gmail Test", email: "g@gmail.test", authType: .oauth2, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "g@gmail.test"
        )
        try database.dbWriter.write { db in try gmailAccount.insert(db) }
        let allMailId = try database.dbWriter.write { db -> Int64 in
            var allMail = MailboxRecord(accountId: gmailAccount.id, path: "[Gmail]/All Mail", displayPath: "All Mail", role: .all, uidValidity: 1)
            try allMail.insert(db)
            return allMail.id!
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertSingleMessageThread(accountId: gmailAccount.id, mailboxId: allMailId, uid: 5, date: date, db: db)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.unarchive, summary: summary, accountId: gmailAccount.id, db: db)
        }
        #expect(snapshot != nil)
        let opCount = try database.dbWriter.read { db in try OpQueueRecord.fetchCount(db) }
        #expect(opCount == 1)
    }

    @Test("unarchiving a message that isn't actually archived (still in INBOX) is a no-op — nothing to reverse")
    func unarchiveSkipsAMessageNotActuallyArchived() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 6, date: date, db: db)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.unarchive, summary: summary, accountId: accountId, db: db)
        }
        #expect(snapshot == nil)

        let (messageStillThere, opCount) = try database.dbWriter.read { db in
            (try MessageRecord.fetchOne(db, key: messageId), try OpQueueRecord.fetchCount(db))
        }
        #expect(messageStillThere != nil)
        #expect(opCount == 0)
    }
}
