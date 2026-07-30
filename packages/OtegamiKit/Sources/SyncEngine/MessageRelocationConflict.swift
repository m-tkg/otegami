import Foundation
import GRDB
import OtegamiStore

/// Task #183 (実機報告「iCloud の Archive メールボックスの同期が毎回 `UNIQUE
/// constraint failed: message.mailboxId, message.uid` で失敗する」): shared
/// conflict resolver for the two call sites that write a `MessageRecord`
/// back onto a specific `(mailboxId, uid)` slot *without first confirming
/// that slot is actually free*:
///
/// - `AccountSyncer.reconcilePendingRelocation` adopts a pending-relocation
///   row's synthetic placeholder `uid` onto the real, server-confirmed one
///   — but a genuine row can already be sitting at that real `(mailboxId,
///   uid)` (e.g. another client's move already synced here for real before
///   this device's own relocation got a chance to reconcile), and rewriting
///   the placeholder's `uid` onto it as if the slot were free trips
///   `message`'s `(mailboxId, uid)` uniqueness constraint.
/// - `MessageRemoval.undo` restores a relocated row's pre-commit
///   `(mailboxId, uid)` — but that original slot can likewise have been
///   reoccupied since (most plausibly a `uidValidity` reset re-syncing a
///   different message into it) while this row sat relocated elsewhere.
///
/// Both resolve a genuine collision the same way `AccountDuplicateMerger
/// .mergeCollidingMailbox` already established for the analogous "two rows
/// for the same physical message" case: the row already occupying the slot
/// (`survivor`) wins, the row trying to move there (`mover`) has its
/// local-only state merged forward into the survivor, and the mover's row
/// is discarded. This is a deliberate, accepted trade-off, not silent data
/// loss — the mover's own cached body/attachments/translation state is
/// dropped (never migrated onto the survivor), exactly like
/// `mergeCollidingMailbox` already does, rather than this call site
/// inventing a different, untested policy for what's otherwise the same
/// shape of problem.
enum MessageRelocationConflict {
    /// Merges `mover`'s local-only state (`isPinnedLocal`, flags,
    /// `detectedLanguage`) into `survivor`, persists `survivor`, and
    /// deletes `mover`'s row (`messageBody`/`attachment`/
    /// `messageTranslation` cascade off `message`'s own foreign key;
    /// `messageSearchIndex` isn't a real foreign-keyed table, so it needs
    /// its own explicit cleanup, same as every other true-removal call
    /// site in this module). A no-op (nothing merged, nothing deleted) if
    /// `mover` has no `id` yet or is already the same row as `survivor`.
    ///
    /// Returns every thread id either row belonged to, so the caller can
    /// refresh `ThreadAssigner.recomputeAggregates` once per affected
    /// thread rather than per merged row.
    @discardableResult
    static func mergeAndDiscard(mover: MessageRecord, into survivor: inout MessageRecord, db: Database) throws -> Set<Int64> {
        guard let moverId = mover.id, moverId != survivor.id else { return [] }
        survivor.isPinnedLocal = survivor.isPinnedLocal || mover.isPinnedLocal
        survivor.flagsRaw |= mover.flagsRaw
        if survivor.detectedLanguage == nil { survivor.detectedLanguage = mover.detectedLanguage }
        try survivor.update(db)
        try FTSIndexer.reindex(messageId: survivor.id ?? 0, db: db)

        var threadIds: Set<Int64> = []
        if let threadId = survivor.threadId { threadIds.insert(threadId) }
        if let threadId = mover.threadId { threadIds.insert(threadId) }

        try FTSIndexer.delete(messageId: moverId, db: db)
        try MessageBodyRecord.deleteOne(db, key: moverId)
        _ = try MessageRecord.deleteOne(db, key: moverId)
        return threadIds
    }
}
