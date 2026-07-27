import Foundation
import GRDB
import OtegamiStore

/// The local-DB half of the swipe/bulk archive and delete actions —
/// "commit the removal immediately, make undo itself fully reversible"
/// rather than delaying the write (see `commit(_:summary:accountId:db:)`'s
/// doc comment for the data-loss bug that design replaced). Pulled out of
/// `MessageListView` (the app target's SwiftUI view that used to own all of
/// this as private methods) into `SyncEngine` so it's exercisable by a
/// plain `AppDatabase.makeInMemory()` unit test — the app-target version had
/// **no** automated coverage of the undo path at all, which is exactly how
/// 実機報告「アーカイブ後に元に戻すが効かない」shipped: `undo(_:db:)` re-inserted a
/// thread's messages *before* re-inserting the thread row itself whenever
/// the removal had emptied (and so deleted) that thread — i.e. every
/// single-message thread, the common case — which trips
/// `message.threadId`'s foreign-key constraint (`AppDatabase`'s
/// `foreignKeysEnabled = true`) and rolls back the whole restore. The
/// surrounding `catch` swallowed that failure silently, so "元に戻す" looked
/// like it did nothing. Fixed here by restoring the thread row first.
public enum MessageRemoval {
    public enum Kind: Sendable {
        case archive
        case delete
        /// D8「迷惑メールにする」— mirrors `.archive`'s shape exactly, just
        /// moving to the account's Junk-role mailbox at replay time
        /// (`OpQueue.enqueueJunk`, resolved/self-healed by
        /// `OpQueueProcessor.resolveOrCreateJunkMailbox` the same way
        /// `.delete` resolves Trash) rather than a pre-resolved local
        /// Archive mailbox id.
        case junk
    }

    /// Everything `undo(_:db:)` needs to reverse one `commit(_:summary:
    /// accountId:db:)` call: the thread's aggregate row and every message
    /// row it actually removed (captured *before* removal, full field
    /// data — re-inserting them restores the exact same `id`s, so nothing
    /// else in the app needs to know a delete/archive was ever reversed),
    /// plus the opQueue row ids that call enqueued (captured via a
    /// before/after max-`id` diff within the same transaction —
    /// `OpQueue.enqueueDelete`/`enqueueArchive` don't themselves return the
    /// id they just inserted).
    public struct Snapshot: Sendable {
        public var thread: ThreadRecord
        public var messages: [MessageRecord]
        public var opQueueIds: [Int64]

        public init(thread: ThreadRecord, messages: [MessageRecord], opQueueIds: [Int64]) {
            self.thread = thread
            self.messages = messages
            self.opQueueIds = opQueueIds
        }
    }

    /// Removes every message `ThreadQuery.actionTargets(for:db:)` returns
    /// for `summary` from its current mailbox and enqueues one archive/
    /// delete op per message — the destination (or, for a Gmail archive,
    /// "no destination — just unlabel") is resolved by `OpQueueProcessor`
    /// at *replay* time, not here at enqueue time (see `OpQueueKind
    /// .archive`'s doc comment for why a pre-resolved local Archive-role
    /// mailbox lookup used to make archiving silently do nothing on a real
    /// Gmail account).
    ///
    /// Commits the local database write (and enqueues the op) *immediately*
    /// — this feature's first version instead delayed the local write
    /// itself so "undo" could just... not commit it, which turned out to
    /// have a real data-loss bug (caught by `scripts/verify-ios-m3.sh`'s
    /// offline swipe-delete phase: an app relaunch inside the old
    /// delayed-commit window silently lost the action, since the pending
    /// `Task.sleep` driving the eventual write died with the process
    /// before ever running). Committing immediately (durable to disk
    /// before this method even returns) and instead making *undo itself*
    /// fully reversible closes that gap: the opQueue row this enqueues
    /// survives any kill regardless of timing, and a normal relaunch's
    /// existing foreground-sync replay picks it up exactly like any other
    /// queued op.
    ///
    /// An archive target already sitting in the account's Archive-role
    /// mailbox (re-archiving an already-archived thread) is skipped rather
    /// than deleted — only messages this call actually removes end up in
    /// the returned `Snapshot.messages`, so `undo(_:db:)` never tries to
    /// re-insert a row that was never deleted in the first place (that
    /// used to be a second, narrower silent-rollback path: re-inserting a
    /// still-present row trips its primary-key uniqueness the same way the
    /// thread-ordering bug trips the `threadId` foreign key).
    @discardableResult
    public static func commit(_ kind: Kind, summary: ThreadSummary, accountId: String, db: Database) throws -> Snapshot? {
        guard let threadId = summary.thread.id else { return nil }
        guard let thread = try ThreadRecord.fetchOne(db, key: threadId) else { return nil }
        let targets = try ThreadQuery.actionTargets(for: summary, db: db)
        let beforeMaxOpId = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM opQueue") ?? 0
        var removedMessages: [MessageRecord] = []
        for message in targets {
            guard let messageId = message.id, let uid = UInt32(exactly: message.uid) else { continue }
            guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
            switch kind {
            case .archive:
                guard mailbox.role != .archive else { continue }
                try OpQueue.enqueueArchive(
                    accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                    uids: [uid], db: db
                )
            case .delete:
                try OpQueue.enqueueDelete(
                    accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                    uids: [uid], db: db
                )
            case .junk:
                try OpQueue.enqueueJunk(
                    accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                    uids: [uid], db: db
                )
            }
            // M7: `messageSearchIndex` isn't a real foreign-keyed table, so
            // this deletion needs its own explicit index cleanup alongside
            // the `message` row's.
            try FTSIndexer.delete(messageId: messageId, db: db)
            try MessageRecord.deleteOne(db, key: messageId)
            removedMessages.append(message)
        }
        guard !removedMessages.isEmpty else { return nil }
        try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        let opQueueIds = try Int64.fetchAll(db, sql: "SELECT id FROM opQueue WHERE id > ? ORDER BY id", arguments: [beforeMaxOpId])
        return Snapshot(thread: thread, messages: removedMessages, opQueueIds: opQueueIds)
    }

    /// Reverses one `commit(_:summary:accountId:db:)` call: deletes the
    /// opQueue rows it enqueued (a no-op for any that already replayed —
    /// `MessageListView.scheduleUndo`'s doc comment covers that race: if
    /// the account's IDLE loop or a manual refresh replayed the op
    /// independently before the undo window elapsed, this deletion is
    /// simply a no-op and only the local restore below applies — a rare,
    /// accepted edge case, not silent data corruption either way) and
    /// re-inserts the thread aggregate row (if `commit` deleted it — i.e.
    /// this was the thread's last remaining message) *before* re-inserting
    /// any removed message, then every removed message with its original
    /// `id` (GRDB's default `insert` includes an already-set primary key
    /// value in the `INSERT` statement, and the row it occupied was just
    /// deleted, so there's no conflict to resolve).
    ///
    /// The thread-before-messages order is load-bearing: `message.threadId`
    /// has a foreign key to `thread` (`AppDatabase.foreignKeysEnabled =
    /// true`), so inserting a message that still points at a thread row
    /// that hasn't been restored yet throws immediately and rolls back the
    /// *entire* transaction — restoring nothing at all. This was the root
    /// cause behind 実機報告「アーカイブ後に元に戻すが効かない」: a thread's last
    /// message being archived/deleted empties (and so deletes) the thread
    /// row, and the previous ordering inserted messages first.
    ///
    /// `FTSIndexer.reindex` restores each message's search-index row the
    /// same way `FTSIndexer.delete` removed it. Best-effort, matching every
    /// other opQueue-enqueuing/db-mutating path in this file — a failure
    /// here just leaves the delete/archive applied, same as if "元に戻す"
    /// had never been tapped.
    public static func undo(_ snapshot: Snapshot, db: Database) throws {
        try OpQueueRecord.deleteAll(db, keys: snapshot.opQueueIds)
        guard let threadId = snapshot.thread.id else { return }
        let threadStillExists = try ThreadRecord.fetchOne(db, key: threadId) != nil
        if !threadStillExists {
            var restoredThread = snapshot.thread
            try restoredThread.insert(db)
        }
        for message in snapshot.messages {
            var restored = message
            try restored.insert(db)
            if let messageId = restored.id {
                try FTSIndexer.reindex(messageId: messageId, db: db)
            }
        }
        if threadStillExists {
            try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        }
    }
}
