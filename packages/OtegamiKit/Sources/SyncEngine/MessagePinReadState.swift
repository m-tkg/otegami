import Foundation
import GRDB
import OtegamiStore

/// The local-DB half of the read/pin toggle actions shared by
/// `MessageListView.applyReadState(_:markingRead:)`/`applyPinState(_:
/// pinning:)` (swipe row + bulk selection), `ThreadDetailView`'s private
/// same-named methods ("…" menu toolbar), and `AccountDigestView`'s private
/// same-named methods (per-account bulk swipe) — three call sites that used
/// to hand-roll the identical flag-update / `OpQueue.enqueueSetFlags` /
/// `ThreadAssigner.recomputeAggregates` loop (`AccountDigestView`'s doc
/// comment even said so explicitly: "`MessageListView.applyReadState`と同じ
/// 実装をこの画面向けに複製している"). Pulled into `SyncEngine`, mirroring
/// `MessageRemoval.commit(_:summary:accountId:db:)`'s own "static function
/// taking `db: Database` directly, App layer just wraps it in
/// `environment.database.dbWriter.write { }`" shape.
///
/// Deliberately does **not** try to also unify how each of the three call
/// sites resolves *which* messages to act on — `MessageListView`/
/// `AccountDigestView` use `OtegamiStore.ThreadQuery.actionTargets(for:db:)`
/// (a `ThreadSummary`-based resolution, aware of flat-mode single-message
/// rows), while `ThreadDetailView` uses its own `targetMessageRecords
/// (threadId:singleMessageId:db:)` (a plain `threadId`/`singleMessageId`
/// pair, no `ThreadSummary` in scope at that call site at all). Both already
/// resolve to the same *kind* of thing (`[MessageRecord]`) they just get
/// there differently, so this only takes the already-resolved array — each
/// caller keeps its own resolution logic unchanged, as a thin wrapper around
/// this.
public enum MessagePinReadState {
    /// Sets every message in `messages` to `markingRead`'s `\Seen` state
    /// (skipping any already there), enqueues an absolute `setFlags` op per
    /// message actually changed (skipped for `message.isPendingRelocation`
    /// — see `MessageReadMarker.markSeen`'s doc comment for the identical,
    /// accepted "no real server UID yet" limitation), then recomputes
    /// `threadId`'s aggregate row. Every write here throws normally (no
    /// `try?`) — callers that need best-effort semantics (all three today)
    /// wrap the whole `dbWriter.write` block in their own `do`/`catch`,
    /// exactly like `MessageRemoval.commit` leaves error handling to its
    /// callers.
    public static func applyReadState(
        markingRead: Bool,
        messages: [MessageRecord],
        threadId: Int64,
        accountId: String,
        db: Database
    ) throws {
        for var message in messages {
            if markingRead {
                guard !message.flags.contains(.seen) else { continue }
                message.flags.insert(.seen)
            } else {
                guard message.flags.contains(.seen) else { continue }
                message.flags.remove(.seen)
            }
            message.updatedAt = Date()
            try message.update(db)
            guard !message.isPendingRelocation,
                  let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId)
            else { continue }
            try OpQueue.enqueueSetFlags(
                accountId: accountId, mailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                uids: [UInt32(message.uid)], flags: message.flags, db: db
            )
        }
        try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
    }

    /// `applyReadState`'s pin counterpart — sets every message in `messages`
    /// to `pinning`'s `isPinnedLocal`/`\Flagged` state (skipping any already
    /// there), enqueues an absolute `setFlags` op per message actually
    /// changed (same `isPendingRelocation` skip), then recomputes
    /// `threadId`'s aggregate row (`ThreadRecord.isPinned`'s doc comment:
    /// the OR-aggregate over its messages that every list/detail screen
    /// reads pin state from).
    public static func applyPinState(
        pinning: Bool,
        messages: [MessageRecord],
        threadId: Int64,
        accountId: String,
        db: Database
    ) throws {
        for var message in messages {
            guard message.isPinnedLocal != pinning else { continue }
            message.isPinnedLocal = pinning
            if pinning {
                message.flags.insert(.flagged)
            } else {
                message.flags.remove(.flagged)
            }
            message.updatedAt = Date()
            try message.update(db)
            guard !message.isPendingRelocation,
                  let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId)
            else { continue }
            try OpQueue.enqueueSetFlags(
                accountId: accountId, mailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                uids: [UInt32(message.uid)], flags: message.flags, db: db
            )
        }
        try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
    }
}
