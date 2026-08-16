import Foundation
import GRDB
import OtegamiStore

/// 「ゴミ箱を空にする」— unlike every action `MessageRemoval` implements
/// (archive/delete/junk and their reverses), this is genuinely
/// irreversible: it hard-deletes every message currently sitting in a
/// Trash-role mailbox from the local database (never a relocation
/// elsewhere — there's nowhere left for a Trash message to go) and
/// enqueues a single `.emptyTrash` op that permanently purges the same
/// messages server-side too (`STORE +FLAGS \Deleted` + `EXPUNGE` against
/// the Trash mailbox itself — see `OpQueueKind.emptyTrash`'s doc comment).
/// Deliberately has no `Snapshot`/`undo(_:db:)` pair the way
/// `MessageRemoval` does — the UI is expected to gate this behind an
/// explicit destructive confirmation (`.alert`, matching this app's other
/// irreversible-action confirmations — see `docs/design-system.md`'s
/// Task #190 note on why `.alert` rather than `.confirmationDialog`)
/// instead of relying on the Undo-toast safety net every other removal in
/// this codebase has.
public enum EmptyTrash {
    /// Permanently removes every message currently in `mailboxId` from the
    /// local database — the caller is expected to have already confirmed
    /// this is in fact a Trash-role mailbox (this doesn't re-check
    /// `MailboxRecord.role` itself, mirroring `MessageRemoval.commit`'s own
    /// "caller already knows which mailbox/role it's acting on" contract).
    ///
    /// Each `message` row is deleted outright (cascading, via
    /// `AppDatabase`'s FK `onDelete: .cascade`, to its `messageBody`/
    /// `attachment` rows — exactly like every other message removal in this
    /// codebase) along with its `messageSearchIndex` FTS row
    /// (`FTSIndexer.delete` — not a real FK table, so this needs its own
    /// explicit cleanup, same as `MessageRemoval.commit`'s own doc comment
    /// explains). Threads left with zero remaining messages are removed too
    /// (`ThreadAssigner.recomputeAggregates`); a thread with messages split
    /// across Trash and elsewhere (e.g. one reply archived, another
    /// deleted) just has its aggregates recomputed, not removed.
    ///
    /// Only messages with a real server UID (`uid >= 1`; `uid <= 0` is the
    /// pending-relocation placeholder sentinel — `docs/architecture.md`'s
    /// offline-first section) are included in the enqueued op's UID list: a
    /// placeholder's relocation hasn't been confirmed by the destination
    /// mailbox's own sync yet, so there's no real server-side UID to purge.
    /// The local row is still hard-deleted either way — a rare placeholder
    /// caught mid-flight simply isn't part of this pass's server-side
    /// purge (nothing server-side references it yet regardless).
    ///
    /// Returns the number of messages actually removed (`0` if the mailbox
    /// was already empty, or didn't exist — no op enqueued in that case).
    @discardableResult
    public static func commit(accountId: String, mailboxId: Int64, db: Database) throws -> Int {
        guard let mailbox = try MailboxRecord.fetchOne(db, key: mailboxId) else { return 0 }
        let messages = try MessageRecord
            .filter(Column("mailboxId") == mailboxId)
            .fetchAll(db)
        guard !messages.isEmpty else { return 0 }

        var purgedUIDs: [UInt32] = []
        var affectedThreadIds: Set<Int64> = []
        for message in messages {
            guard let messageId = message.id else { continue }
            if message.uid >= 1, let uid = UInt32(exactly: message.uid) {
                purgedUIDs.append(uid)
            }
            if let threadId = message.threadId {
                affectedThreadIds.insert(threadId)
            }
            try FTSIndexer.delete(messageId: messageId, db: db)
            try MessageRecord.deleteOne(db, key: messageId)
        }
        for threadId in affectedThreadIds {
            try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        }
        try OpQueue.enqueueEmptyTrash(
            accountId: accountId, mailboxId: mailboxId, uidValidity: mailbox.uidValidity,
            uids: purgedUIDs, db: db
        )
        return messages.count
    }
}
