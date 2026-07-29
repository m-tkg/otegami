import Foundation
import GRDB
import OtegamiStore

/// Task #96 (実機報告「未読メールを開き、本文の読み込みが完了する前に一覧へ戻ると
/// 既読にならない」): the local-DB half of "open a message → mark it read",
/// pulled out of `MessageView` (the app target's SwiftUI view) into
/// `SyncEngine` for the same reason `MessageRemoval` was — exercisable by a
/// plain `AppDatabase.makeInMemory()` unit test, with no dependency on
/// SwiftUI's view lifecycle at all.
///
/// The root cause this fixes: `MessageView` used to call its own
/// (now-deleted) `markAsReadIfNeeded()` only *after* the message body had
/// finished loading — either the "already cached" branch or the "just
/// fetched over the network" branch of `load()`, itself running inside
/// `.task(id: messageId) { await load() }`. A message opened right before a
/// slow network body fetch, then closed (popping back to the list) before
/// that fetch resolved, cancels `.task`'s own `Task` while it's still
/// suspended *inside* `fetchBodyOverNetwork` — execution never reaches
/// either post-fetch call site, so `\Seen` is never applied at all. Real
/// devices with slow networks hit this reliably.
///
/// The fix: `MessageView` now calls into this type from `.onAppear` (fired
/// synchronously the instant the view mounts — a thread-collapsed row's
/// expand, or a direct push — completely independent of `.task`'s
/// lifecycle) via its own still-unstructured `Task { }` wrapper, so the
/// write below runs to completion even if the view's own `.task`-scoped
/// work is cancelled moments later. `markSeen`'s `!record.flags.contains
/// (.seen)` guard also makes every one of `MessageView`'s remaining call
/// sites (the post-fetch branches still call this too, now just as a
/// harmless no-op on the common path) safely idempotent — only the first
/// call to actually observe the message unread does any work.
public enum MessageReadMarker {
    /// Flips `\Seen` on `messageId`'s row and enqueues the resulting
    /// absolute flag state for `OpQueueProcessor` to mirror to the server —
    /// mirrors the swipe/bulk "mark as read" write `MessageListView`/
    /// `ThreadDetailView` already do inline. Returns `false` (no-op) if the
    /// message doesn't exist, is already `\Seen`, or its mailbox can't be
    /// resolved — the caller decides whether a replay attempt is worth
    /// making from that.
    @discardableResult
    public static func markSeen(messageId: Int64, accountId: String, db: Database) throws -> Bool {
        guard var record = try MessageRecord.fetchOne(db, key: messageId) else { return false }
        guard !record.flags.contains(.seen) else { return false }
        record.flags.insert(.seen)
        record.updatedAt = Date()
        try record.update(db)
        // Task #120: a `MessageRecord.isPendingRelocation` row has no real
        // server UID to `STORE` this flag against yet — the local write
        // above already applied (so the row reads \Seen immediately), but
        // mirroring it to the server has to wait until this mailbox's next
        // sync reconciles the row (`AccountSyncer.reconcilePendingRelocation`).
        // Known, accepted limitation: if the pending window closes with the
        // server's own copy of this message *not* already \Seen, that
        // resync's envelope refresh overwrites `flagsRaw` back to the
        // server's state (only `createdAt`/`threadId`/`isPinnedLocal` are
        // protected from a resync overwrite — see `AccountSyncer.upsert`'s
        // doc comment) and this optimistic mark-as-read can be silently
        // lost. Narrow window in practice (the op queue usually replays,
        // and the destination syncs, within moments), not attempted here.
        if !record.isPendingRelocation, let mailbox = try MailboxRecord.fetchOne(db, key: record.mailboxId) {
            try OpQueue.enqueueSetFlags(
                accountId: accountId, mailboxId: record.mailboxId, uidValidity: mailbox.uidValidity,
                uids: [UInt32(record.uid)], flags: record.flags, db: db
            )
        }
        if let threadId = record.threadId {
            try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        }
        return true
    }
}
