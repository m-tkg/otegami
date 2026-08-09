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
    ///
    /// Returns whether **any** row was actually written — the representative
    /// row or one of its duplicate siblings. `MessageReadMarker.markSeen`
    /// (this function's single-message wrapper) hands that answer to callers
    /// deciding whether an op queue replay is worth attempting; "only a
    /// sibling was out of step" still enqueues a `setFlags` op, so it counts.
    @discardableResult
    public static func applyReadState(
        markingRead: Bool,
        messages: [MessageRecord],
        threadId: Int64,
        accountId: String,
        db: Database
    ) throws -> Bool {
        var didWriteAny = false
        for var message in messages {
            // `didWrite`の判断理由は`applyPinState`の同じ箇所を参照 —
            // 代表行が既に目的の状態でも、兄弟行がズレていれば処理を
            // 続ける (早期 continue しない)。
            var didWrite = false
            if message.flags.contains(.seen) != markingRead {
                if markingRead {
                    message.flags.insert(.seen)
                } else {
                    message.flags.remove(.seen)
                }
                message.updatedAt = Date()
                try message.update(db)
                didWrite = true
            }
            // Gmail の二重ラベルで畳まれた兄弟行にも同じローカル状態を書く
            // (`ThreadQuery.duplicateSiblings(of:db:)`の doc comment) —
            // 呼び出し側が渡してくるのは dedup 済みの代表行だけなので、
            // これが無いと片方の行だけ古い値のまま残る。
            if try applyToDuplicateSiblings(of: message, db: db, transform: { sibling in
                guard sibling.flags.contains(.seen) != markingRead else { return nil }
                var updated = sibling
                if markingRead {
                    updated.flags.insert(.seen)
                } else {
                    updated.flags.remove(.seen)
                }
                return updated
            }) {
                didWrite = true
            }
            if didWrite { didWriteAny = true }
            guard didWrite,
                  !message.isPendingRelocation,
                  let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId)
            else { continue }
            try OpQueue.enqueueSetFlags(
                accountId: accountId, mailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                uids: [UInt32(message.uid)], flags: message.flags, db: db
            )
        }
        try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        return didWriteAny
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
            // 実機報告 (2026-08-07)「メールの unpin が反映されない」の
            // **2番目の層**: ここは元々`guard message.isPinnedLocal !=
            // pinning else { continue }`で、代表行の状態だけを見て打ち切って
            // いた。ところが「代表行は解除済み、同期が戻した All Mail 側の
            // 兄弟行だけ`true`」という状態になると、`ThreadRecord.isPinned`
            // (当時は dedup 前の OR) は`true`で UI にはピンが出ているのに、
            // 解除タップは代表行が既に`false`なので即 continue — 下の兄弟行
            // 同期にすら到達せず、**何度タップしても完全に何も起きない**
            // 状態だった。
            //
            // 打ち切りの条件を「代表行の状態」から「実際に DB を書いたか
            // (`didWrite`)」へ移す。全行が既に目的の状態なら従来どおり op を
            // 積まないまま (グループ一括操作が無駄な op を積まないための
            // `AccountDigestPresentation.bulkActionTargets` と同じ方針)、
            // 兄弟行だけズレていたときは op を1件積む — その状態は
            // 「サーバー側がユーザーの意図と食い違ったまま残っている」証拠
            // なので、絶対値の`setFlags`(冪等) を積み直してサーバーへ改めて
            // 表明するのが正しい。恒久失敗した古い op が残っていても、新しい
            // op は`attempts = 0`から再試行されるので、ユーザーのタップが
            // 実質リトライになるという副次的な効用もある。
            //
            // 同じ方向のタップを繰り返しても、1回目で全行が揃うので2回目
            // 以降は op ゼロになる (`OpQueue.enqueue`は coalesce せず毎回
            // INSERT するので、この上限が効くことが重要)。
            var didWrite = false
            if message.isPinnedLocal != pinning {
                message.isPinnedLocal = pinning
                if pinning {
                    message.flags.insert(.flagged)
                } else {
                    message.flags.remove(.flagged)
                }
                message.updatedAt = Date()
                try message.update(db)
                didWrite = true
            }
            // Gmail の二重ラベルで畳まれた兄弟行にも同じローカル状態を書く
            // (`ThreadQuery.duplicateSiblings(of:db:)`の doc comment)。
            if try applyToDuplicateSiblings(of: message, db: db, transform: { sibling in
                guard sibling.isPinnedLocal != pinning else { return nil }
                var updated = sibling
                updated.isPinnedLocal = pinning
                if pinning {
                    updated.flags.insert(.flagged)
                } else {
                    updated.flags.remove(.flagged)
                }
                return updated
            }) {
                didWrite = true
            }
            guard didWrite,
                  !message.isPendingRelocation,
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
    /// 戻り値は**1行でも実際に書いたか** — 呼び出し側はこれを見て
    /// `setFlags` op を積むかどうかを決める (判断理由は`applyPinState`の
    /// `didWrite`のコメント)。
    ///
    /// `opQueue` には積まない — Gmail のフラグはラベルではなくメッセージに
    /// 付くので、代表行のぶんの op を送れば両方に反映される。ここで揃える
    /// のはローカル DB の整合性だけ。**その代わり、兄弟行の`(mailboxId,
    /// uid)`を守る op が存在しない**ので、同期側のガード
    /// (`PendingOpTargets.forMailbox`) が代表行の op から兄弟行の UID を
    /// 辿ってガードを広げている — 片方だけ直すと、揃えた直後に同期が
    /// 元へ戻す (実機報告 2026-08-07 の1度目の修正がまさにそれだった)。
    @discardableResult
    private static func applyToDuplicateSiblings(
        of message: MessageRecord,
        db: Database,
        transform: (MessageRecord) -> MessageRecord?
    ) throws -> Bool {
        var didWrite = false
        for sibling in try ThreadQuery.duplicateSiblings(of: message, db: db) {
            guard var updated = transform(sibling) else { continue }
            updated.updatedAt = Date()
            try updated.update(db)
            didWrite = true
        }
        return didWrite
    }
}
