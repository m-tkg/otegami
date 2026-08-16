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

    // 実機報告「メールを削除しても検索で出てくるし中身が見える」: `.delete`
    // は (Task #120 以降) ローカルではゴミ箱メールボックスへ「移送」するだけで
    // `message`/`messageBody`/`messageSearchIndex` 行は残る (意図された即時
    // 反映、この型の doc comment 参照)。以前は `makeDatabase()` が INBOX しか
    // 作らないため `.delete` のテストが「ローカルにゴミ箱が無い＝ハード削除」
    // ブランチしか通っておらず、この移送ブランチ (かつ検索から除外される
    // べきという要件) は自動テストで一切確認されていなかった。
    @Test("delete relocates the message into a local Trash mailbox rather than hard-deleting it, and the trashed message is excluded from cross-account search but still findable inside Trash itself")
    func deleteRelocatesToTrashAndIsExcludedFromSearch() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let trashId = try database.dbWriter.write { db -> Int64 in
            var trash = MailboxRecord(accountId: accountId, path: "Trash", displayPath: "Trash", role: .trash, uidValidity: 1)
            try trash.insert(db)
            return trash.id!
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db in
            let (threadId, messageId) = try insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 9, date: date, db: db)
            var message = try MessageRecord.fetchOne(db, key: messageId)!
            message.subject = "削除済みメールの本文が検索で見える"
            try message.update(db)
            try FTSIndexer.reindex(messageId: messageId, db: db)
            return (threadId, messageId)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }

        _ = try database.dbWriter.write { db in
            try MessageRemoval.commit(.delete, summary: summary, accountId: accountId, db: db)
        }

        // Relocated, not hard-deleted: the row still exists, now filed
        // under the local Trash mailbox.
        let messageAfterDelete = try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) }
        #expect(messageAfterDelete?.mailboxId == trashId)

        // Cross-account search must not surface it (the reported bug).
        let acrossAllMailboxes = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "削除済みメール", scope: .allAccounts(accountIds: [accountId]), db: db)
        }
        #expect(!acrossAllMailboxes.contains { $0.latestMessage?.id == messageId })

        // Explicitly opening the Trash mailbox and searching inside it
        // still finds the message — search only excludes trash/junk from
        // the *cross-account* scope, not from an explicit mailbox scope.
        let insideTrashItself = try database.dbWriter.read { db in
            try SearchQuery.threadSummaries(query: "削除済みメール", scope: .mailbox(mailboxId: trashId), db: db)
        }
        #expect(insideTrashItself.contains { $0.latestMessage?.id == messageId })
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

        // Task #120: `archiveId` (an Archive-role mailbox) is already known
        // locally here, so `commit` relocates the inbox copy into it
        // immediately (pending a real UID) rather than deleting it — the
        // row survives with the same `id`, just a new `mailboxId`/`uid`.
        let (messageAfterArchive, archivedMessageStillThere, threadAfterArchive) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: inboxMessageId),
                try MessageRecord.fetchOne(db, key: archivedMessageId),
                try ThreadRecord.fetchOne(db, key: threadId)
            )
        }
        #expect(messageAfterArchive?.mailboxId == archiveId)
        #expect(messageAfterArchive?.isPendingRelocation == true)
        #expect(archivedMessageStillThere != nil)
        #expect(archivedMessageStillThere?.mailboxId == archiveId)
        #expect(archivedMessageStillThere?.isPendingRelocation == false, "the already-archived message must be untouched, still its real UID")
        #expect(threadAfterArchive != nil)
        #expect(threadAfterArchive?.messageCount == 2, "relocating never removes a message, so the thread's count is unaffected")

        // Undo must not throw (relocated back via `update`, not a
        // duplicate-primary-key `insert` of a still-present row) and must
        // restore the inbox copy's original mailbox/UID.
        try database.dbWriter.write { db in try MessageRemoval.undo(snapshot2, db: db) }
        let (messageAfterUndo, threadAfterUndo) = try database.dbWriter.read { db in
            (try MessageRecord.fetchOne(db, key: inboxMessageId), try ThreadRecord.fetchOne(db, key: threadId))
        }
        #expect(messageAfterUndo?.mailboxId == inboxId)
        #expect(messageAfterUndo?.uid == 1)
        #expect(messageAfterUndo?.isPendingRelocation == false)
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

    // MARK: markSeenOnArchive (実機フィードバック「アーカイブ時に既読にする」)

    @Test("commit(.archive, markSeenOnArchive: true) marks the relocated row \\Seen and enqueues the flag op before the archive op")
    func archiveWithMarkSeenOnArchiveMarksRelocatedRowSeenInOpOrder() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        // Task #120 の relocation を発火させるため、Archive-role mailbox を
        // あらかじめ用意しておく（`archiveSkipsAlreadyArchivedMessageAndUndoStaysConsistent`
        // と同じセットアップ）。
        let archiveId = try database.dbWriter.write { db -> Int64 in
            var archive = MailboxRecord(accountId: accountId, path: "Archive", displayPath: "Archive", role: .archive, uidValidity: 1)
            try archive.insert(db)
            return archive.id!
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 11, date: date, db: db)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }
        #expect(summary.latestMessage?.flags.contains(.seen) == false, "insertSingleMessageThread's messages start unread")

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db, markSeenOnArchive: true)
        }
        let snapshot2 = try #require(snapshot)

        // Relocated (not deleted, since `archiveId` is known locally) and
        // now \Seen.
        let (messageAfterArchive, opsAfterArchive) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try OpQueueRecord.order(Column("id")).fetchAll(db)
            )
        }
        #expect(messageAfterArchive?.mailboxId == archiveId)
        #expect(messageAfterArchive?.isPendingRelocation == true)
        #expect(messageAfterArchive?.flags.contains(.seen) == true)

        // Ordering matters: `OpQueueProcessor` replays by id order, so the
        // flag STORE op must precede the archive (move) op — a flag STORE
        // against a UID that's already been moved by an earlier archive op
        // would fail.
        #expect(opsAfterArchive.map(\.kind) == [OpQueueKind.setFlags.rawValue, OpQueueKind.archive.rawValue])

        // The undo snapshot keeps the *pre-markSeen* copy — see `commit`'s
        // doc comment on why (undo restores the unread state too, and the
        // flag op is captured in `opQueueIds` alongside the archive op so
        // undo cancels both together).
        #expect(snapshot2.messages.first?.flags.contains(.seen) == false)
        #expect(snapshot2.opQueueIds.count == 2)
    }

    @Test("commit(.archive) defaults to markSeenOnArchive: false — no flag op, seen state untouched")
    func archiveDefaultsToNotMarkingSeen() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let archiveId = try database.dbWriter.write { db -> Int64 in
            var archive = MailboxRecord(accountId: accountId, path: "Archive", displayPath: "Archive", role: .archive, uidValidity: 1)
            try archive.insert(db)
            return archive.id!
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 12, date: date, db: db)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }

        // No `markSeenOnArchive` argument — must match every pre-existing
        // call site's behavior exactly.
        try database.dbWriter.write { db in
            try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }

        let (messageAfterArchive, opKindsAfterArchive) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try OpQueueRecord.fetchAll(db).map(\.kind)
            )
        }
        #expect(messageAfterArchive?.mailboxId == archiveId)
        #expect(messageAfterArchive?.flags.contains(.seen) == false)
        #expect(opKindsAfterArchive == [OpQueueKind.archive.rawValue])
    }

    /// Deliberately *without* a locally-known Archive-role mailbox (unlike
    /// the two tests above) — no relocation happens, so `commit` takes the
    /// "no destination known" branch (`else` in its own loop: `FTSIndexer
    /// .delete` + `MessageRecord.deleteOne`) and `undo` fully re-inserts
    /// `original` (`undoRestoresSingleMessageThreadAfterArchive`'s same
    /// setup). This is the branch where the "markSeen 前の元コピーを
    /// `removedMessages` に積む" design actually pays off: a full row
    /// re-insert restores *every* field from that pre-markSeen snapshot,
    /// including `flags` — unlike the relocated-row branch tested above,
    /// which (by existing, documented design — `undo`'s doc comment) only
    /// restores `mailboxId`/`uid` and deliberately leaves every other field
    /// (including a since-changed read state) alone.
    @Test("undo after markSeenOnArchive archive (no known Archive mailbox → delete+reinsert) restores the unread state and cancels both the flag and archive ops")
    func undoAfterMarkSeenOnArchiveRestoresUnreadStateWhenReinserted() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 13, date: date, db: db)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }
        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db, markSeenOnArchive: true)
        }
        let snapshot2 = try #require(snapshot)
        #expect(try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) } == nil, "no Archive mailbox known locally → deleted, not relocated")

        try database.dbWriter.write { db in try MessageRemoval.undo(snapshot2, db: db) }

        let (messageAfterUndo, opCountAfterUndo) = try database.dbWriter.read { db in
            (try MessageRecord.fetchOne(db, key: messageId), try OpQueueRecord.fetchCount(db))
        }
        #expect(messageAfterUndo?.mailboxId == inboxId)
        #expect(messageAfterUndo?.uid == 13)
        #expect(messageAfterUndo?.flags.contains(.seen) == false, "undo restores the unread state, not just the location")
        #expect(opCountAfterUndo == 0, "both the flag op and the archive op are cancelled together")
    }

    // MARK: unarchive (Task #87, 1)

    @Test("unarchive → undo restores a single-message thread the same way archive does, and enqueues an unarchive op")
    func undoRestoresSingleMessageThreadAfterUnarchive() throws {
        // `makeDatabase()` always creates an INBOX-role mailbox internally
        // (Task #120: `commit(.unarchive, ...)` relocates into it, since
        // it's known locally the moment an account exists at all).
        let (database, accountId, inboxId) = try makeDatabase()
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

        // Task #120: relocated into INBOX (pending a real UID), not
        // deleted — the thread survives too, since the message never
        // actually left the `message` table.
        let (messageAfterUnarchive, threadAfterUnarchive, opCountAfterUnarchive, opKindAfterUnarchive) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try ThreadRecord.fetchOne(db, key: threadId),
                try OpQueueRecord.fetchCount(db),
                try OpQueueRecord.fetchOne(db)?.kind
            )
        }
        #expect(messageAfterUnarchive?.mailboxId == inboxId)
        #expect(messageAfterUnarchive?.isPendingRelocation == true)
        #expect(threadAfterUnarchive?.messageCount == 1)
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
        #expect(messageAfterUndo?.mailboxId == archiveId)
        #expect(messageAfterUndo?.uid == 4)
        #expect(messageAfterUndo?.isPendingRelocation == false)
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

    // MARK: pinned archive guard (Task #163)

    @Test("archiving a pinned thread throws ArchiveGuardError.pinned instead of removing anything")
    func archiveThrowsForPinnedThread() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db -> (Int64, Int64) in
            let ids = try insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 11, date: date, db: db)
            var message = try MessageRecord.fetchOne(db, key: ids.messageId)!
            message.isPinnedLocal = true
            try message.update(db)
            try ThreadAssigner.recomputeAggregates(threadId: ids.threadId, db: db)
            return ids
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }
        #expect(summary.thread.isPinned == true)

        #expect(throws: MessageRemoval.ArchiveGuardError.pinned) {
            try database.dbWriter.write { db in
                try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
            }
        }

        // Nothing was touched: the message is still in the inbox, no op
        // was queued.
        let (messageAfter, opCount) = try database.dbWriter.read { db in
            (try MessageRecord.fetchOne(db, key: messageId), try OpQueueRecord.fetchCount(db))
        }
        #expect(messageAfter?.mailboxId == inboxId)
        #expect(opCount == 0)
    }

    @Test("deleting a pinned thread still works — only .archive is guarded")
    func deleteStillWorksForPinnedThread() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db -> (Int64, Int64) in
            let ids = try insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 12, date: date, db: db)
            var message = try MessageRecord.fetchOne(db, key: ids.messageId)!
            message.isPinnedLocal = true
            try message.update(db)
            try ThreadAssigner.recomputeAggregates(threadId: ids.threadId, db: db)
            return ids
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }
        #expect(summary.thread.isPinned == true)

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.delete, summary: summary, accountId: accountId, db: db)
        }
        #expect(snapshot != nil)
        let messageAfter = try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) }
        #expect(messageAfter == nil)
    }

    @Test("junking a pinned thread still works — only .archive is guarded")
    func junkStillWorksForPinnedThread() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db -> (Int64, Int64) in
            let ids = try insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 13, date: date, db: db)
            var message = try MessageRecord.fetchOne(db, key: ids.messageId)!
            message.isPinnedLocal = true
            try message.update(db)
            try ThreadAssigner.recomputeAggregates(threadId: ids.threadId, db: db)
            return ids
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.junk, summary: summary, accountId: accountId, db: db)
        }
        #expect(snapshot != nil)
    }

    @Test("unarchiving a pinned message still works — only .archive is guarded, not .unarchive")
    func unarchiveStillWorksForPinnedThread() throws {
        let (database, accountId, _) = try makeDatabase()
        let archiveId = try database.dbWriter.write { db -> Int64 in
            var archive = MailboxRecord(accountId: accountId, path: "Archive", displayPath: "Archive", role: .archive, uidValidity: 1)
            try archive.insert(db)
            return archive.id!
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db -> (Int64, Int64) in
            let ids = try insertSingleMessageThread(accountId: accountId, mailboxId: archiveId, uid: 14, date: date, db: db)
            var message = try MessageRecord.fetchOne(db, key: ids.messageId)!
            message.isPinnedLocal = true
            try message.update(db)
            try ThreadAssigner.recomputeAggregates(threadId: ids.threadId, db: db)
            return ids
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
        #expect(snapshot != nil)
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

    // MARK: unjunk (「迷惑メール解除」)

    @Test("unjunk → undo restores a single-message thread the same way unarchive does, and enqueues an unjunk op")
    func undoRestoresSingleMessageThreadAfterUnjunk() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let junkId = try database.dbWriter.write { db -> Int64 in
            var junk = MailboxRecord(accountId: accountId, path: "Junk", displayPath: "Junk", role: .junk, uidValidity: 1)
            try junk.insert(db)
            return junk.id!
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertSingleMessageThread(accountId: accountId, mailboxId: junkId, uid: 11, date: date, db: db)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.unjunk, summary: summary, accountId: accountId, db: db)
        }
        let snapshot2 = try #require(snapshot)

        let (messageAfterUnjunk, threadAfterUnjunk, opCountAfterUnjunk, opKindAfterUnjunk) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try ThreadRecord.fetchOne(db, key: threadId),
                try OpQueueRecord.fetchCount(db),
                try OpQueueRecord.fetchOne(db)?.kind
            )
        }
        #expect(messageAfterUnjunk?.mailboxId == inboxId)
        #expect(messageAfterUnjunk?.isPendingRelocation == true)
        #expect(threadAfterUnjunk?.messageCount == 1)
        #expect(opCountAfterUnjunk == 1)
        #expect(opKindAfterUnjunk == OpQueueKind.unjunk.rawValue)

        try database.dbWriter.write { db in try MessageRemoval.undo(snapshot2, db: db) }

        let (threadAfterUndo, messageAfterUndo, opCountAfterUndo) = try database.dbWriter.read { db in
            (
                try ThreadRecord.fetchOne(db, key: threadId),
                try MessageRecord.fetchOne(db, key: messageId),
                try OpQueueRecord.fetchCount(db)
            )
        }
        #expect(threadAfterUndo != nil)
        #expect(messageAfterUndo?.mailboxId == junkId)
        #expect(messageAfterUndo?.uid == 11)
        #expect(messageAfterUndo?.isPendingRelocation == false)
        #expect(opCountAfterUndo == 0)
    }

    @Test("unjunking a message that isn't actually in Junk (still in INBOX) is a no-op — nothing to reverse")
    func unjunkSkipsAMessageNotActuallyInJunk() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db in
            try insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 12, date: date, db: db)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(
                thread: try ThreadRecord.fetchOne(db, key: threadId)!,
                latestMessage: try MessageRecord.fetchOne(db, key: messageId)
            )
        }

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.unjunk, summary: summary, accountId: accountId, db: db)
        }
        #expect(snapshot == nil)

        let (messageStillThere, opCount) = try database.dbWriter.read { db in
            (try MessageRecord.fetchOne(db, key: messageId), try OpQueueRecord.fetchCount(db))
        }
        #expect(messageStillThere != nil)
        #expect(opCount == 0)
    }

    // MARK: undo vs. a reoccupied original slot (Task #183)

    /// Task #183 (実機報告「iCloud の Archive メールボックスの同期が毎回
    /// `UNIQUE constraint failed: message.mailboxId, message.uid` で失敗する」):
    /// `undo`'s "still exists (relocated)" branch used to write `original`'s
    /// pre-commit `(mailboxId, uid)` straight back onto the relocated row
    /// without checking whether some *other* row had genuinely landed at
    /// that exact slot in the meantime (most plausibly a `uidValidity`
    /// reset re-syncing an unrelated message into it) — tripping the same
    /// `(mailboxId, uid)` uniqueness constraint `reconcilePendingRelocation`
    /// could. This locks in the fix: undo must not crash, the row already
    /// occupying the slot survives, and the row that couldn't reclaim its
    /// slot has its local-only pin state merged forward before being
    /// discarded (`MessageRelocationConflict`'s policy, mirroring
    /// `AccountDuplicateMerger.mergeCollidingMailbox`).
    @Test("undo after the original slot got reoccupied merges local state into the occupant instead of crashing")
    func undoCollisionWithReoccupiedSlotMergesInsteadOfCrashing() throws {
        let (database, accountId, inboxId) = try makeDatabase()
        let archiveId = try database.dbWriter.write { db -> Int64 in
            var archive = MailboxRecord(accountId: accountId, path: "Archive", displayPath: "Archive", role: .archive, uidValidity: 1)
            try archive.insert(db)
            return archive.id!
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let (threadId, messageId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: date, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(
                mailboxId: inboxId, uid: 1, date: date, internalDate: date,
                threadId: thread.id, isPinnedLocal: true
            )
            try message.insert(db)
            return (thread.id!, message.id!)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(thread: try ThreadRecord.fetchOne(db, key: threadId)!, latestMessage: try MessageRecord.fetchOne(db, key: messageId))
        }

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
        }
        let snapshot2 = try #require(snapshot)

        // Task #120: `archiveId` is known locally, so this relocated
        // (same row id, placeholder UID) rather than deleted.
        let relocated = try database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId) }
        #expect(relocated?.mailboxId == archiveId)
        #expect(relocated?.isPendingRelocation == true)

        // The original slot — `(inboxId, uid: 1)` — gets reoccupied by a
        // genuinely different message while this row sat relocated in
        // Archive (e.g. a `uidValidity` reset resyncing INBOX from
        // scratch).
        let (occupantThreadId, occupantMessageId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var occupantThread = ThreadRecord(accountId: accountId, lastMessageDate: date, messageCount: 1)
            try occupantThread.insert(db)
            var occupant = MessageRecord(
                mailboxId: inboxId, uid: 1, messageId: "<reoccupant@otegami.test>",
                date: date, internalDate: date, threadId: occupantThread.id
            )
            try occupant.insert(db)
            return (occupantThread.id!, occupant.id!)
        }

        // Before this task's fix, this threw `UNIQUE constraint failed:
        // message.mailboxId, message.uid` writing `messageId`'s original
        // `(inboxId, uid: 1)` straight back onto it.
        try database.dbWriter.write { db in try MessageRemoval.undo(snapshot2, db: db) }

        let (archivedRowAfterUndo, archivedThreadAfterUndo, occupantAfterUndo, occupantThreadAfterUndo) = try database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: messageId),
                try ThreadRecord.fetchOne(db, key: threadId),
                try MessageRecord.fetchOne(db, key: occupantMessageId),
                try ThreadRecord.fetchOne(db, key: occupantThreadId)
            )
        }
        #expect(archivedRowAfterUndo == nil, "the row that couldn't reclaim its original slot is discarded rather than left duplicated")
        #expect(archivedThreadAfterUndo == nil, "its now-empty original thread is cleaned up the same way any other empty thread is")
        #expect(occupantAfterUndo != nil, "the row already occupying the slot survives")
        #expect(occupantAfterUndo?.isPinnedLocal == true, "the discarded row's local-only pin state is merged forward onto the survivor")
        #expect(occupantThreadAfterUndo?.messageCount == 1)
    }

    /// 実機報告 (2026-08-16, Gmail アカウント)「特定の1通に対して削除・
    /// アーカイブ解除・未読化が完全無反応 (エラー表示も無し)」の修正 (2):
    /// `commit`の target がそれ自身 `MessageRecord.isPendingRelocation`
    /// (`uid <= 0`) — 直前の別操作がまだサーバー確認待ちで移送中の行、
    /// あるいは R3/staleDiscarded で永久に取り残されたゴースト行のどちら
    /// か — のとき、修正前は `guard let uid = UInt32(exactly: message.uid)
    /// else { continue }` で行全体が丸ごと skip され、ローカルの削除も
    /// 一切実行されないまま `commit` は `nil` を返していた (エラー表示も
    /// 無い完全な無反応 — 呼び出し元の UI の各 guard がそのまま抜けて
    /// 終わる)。
    @Test("commit(.delete) on a MessageRecord.isPendingRelocation row deletes it locally and returns a non-nil snapshot, without enqueuing a server op")
    func commitDeleteOnGhostRowDeletesLocallyWithoutEnqueuingOp() throws {
        let (database, accountId, _) = try makeDatabase()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        // No Trash-role mailbox exists locally, so `destinationMailbox`
        // resolves to `nil` and the local effect is a hard delete — the
        // same "no destination known yet" fallback a real (non-ghost) row
        // already uses. `uid: -1` mirrors `MessageRemoval.commit`'s own
        // `uid = -messageId` convention for an already-relocated row —
        // this one simulates a leftover ghost sitting in some other
        // mailbox (Archive here; the exact mailbox doesn't matter).
        let (threadId, messageId) = try database.dbWriter.write { db -> (Int64, Int64) in
            var archive = MailboxRecord(accountId: accountId, path: "Archive", displayPath: "Archive", role: .archive, uidValidity: 1)
            try archive.insert(db)
            var thread = ThreadRecord(accountId: accountId, lastMessageDate: date, messageCount: 1)
            try thread.insert(db)
            var message = MessageRecord(
                mailboxId: archive.id!, uid: -1, date: date, internalDate: date, threadId: thread.id
            )
            try message.insert(db)
            return (thread.id!, message.id!)
        }
        let summary = try database.dbWriter.read { db in
            ThreadSummary(thread: try ThreadRecord.fetchOne(db, key: threadId)!, latestMessage: try MessageRecord.fetchOne(db, key: messageId))
        }

        let snapshot = try database.dbWriter.write { db in
            try MessageRemoval.commit(.delete, summary: summary, accountId: accountId, db: db)
        }
        #expect(snapshot != nil, "before the fix, the ghost row was silently skipped and commit returned nil — exactly the 'no error, nothing happens' bug the real-device report described")
        #expect(snapshot?.messages.count == 1)

        let (messageAfterDelete, opCount) = try database.dbWriter.read { db in
            (try MessageRecord.fetchOne(db, key: messageId), try OpQueueRecord.fetchCount(db))
        }
        #expect(messageAfterDelete == nil, "the ghost row is hard-deleted locally")
        #expect(opCount == 0, "no server op is enqueued for a row with no real UID to reference")
    }
}
