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
            // Gmail の二重ラベルで畳まれた兄弟行にも同じローカル状態を書く
            // (`ThreadQuery.duplicateSiblings(of:db:)`の doc comment) —
            // 呼び出し側が渡してくるのは dedup 済みの代表行だけなので、
            // これが無いと片方の行だけ古い値のまま残る。
            try applyToDuplicateSiblings(of: message, db: db) { sibling in
                guard sibling.flags.contains(.seen) != markingRead else { return nil }
                var updated = sibling
                if markingRead {
                    updated.flags.insert(.seen)
                } else {
                    updated.flags.remove(.seen)
                }
                return updated
            }
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
            // 実機報告 (2026-08-07)「メールの unpin が反映されない」の実体:
            // `ThreadRecord.isPinned` は dedup 前の全行の OR なので、代表行
            // だけ解除しても Gmail の All Mail 側の行が `isPinnedLocal ==
            // true` のまま残り、スレッドのピンが落ちなかった (逆にピン留めは
            // OR なので代表行だけで効いてしまい、非対称なバグに見えていた)。
            // 兄弟行にも同じローカル状態を書いて揃える
            // (`ThreadQuery.duplicateSiblings(of:db:)`の doc comment)。
            try applyToDuplicateSiblings(of: message, db: db) { sibling in
                guard sibling.isPinnedLocal != pinning else { return nil }
                var updated = sibling
                updated.isPinnedLocal = pinning
                if pinning {
                    updated.flags.insert(.flagged)
                } else {
                    updated.flags.remove(.flagged)
                }
                return updated
            }
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

    /// `message` の重複兄弟行 (`ThreadQuery.duplicateSiblings(of:db:)`) に
    /// `transform` を適用して保存する。`transform` が `nil` を返した行は
    /// 既に目的の状態なので触らない (`updatedAt` を無意味に動かさないため)。
    ///
    /// `opQueue` には積まない — Gmail のフラグはラベルではなくメッセージに
    /// 付くので、代表行のぶんの op を送れば両方に反映される。ここで揃える
    /// のはローカル DB の整合性だけ。
    private static func applyToDuplicateSiblings(
        of message: MessageRecord,
        db: Database,
        transform: (MessageRecord) -> MessageRecord?
    ) throws {
        for sibling in try ThreadQuery.duplicateSiblings(of: message, db: db) {
            guard var updated = transform(sibling) else { continue }
            updated.updatedAt = Date()
            try updated.update(db)
        }
    }
}
