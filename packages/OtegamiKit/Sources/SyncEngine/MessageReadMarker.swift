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
    /// Flips `\Seen` on `messageId`'s row (and, for a Gmail message that is
    /// stored under two labels, on its duplicate sibling row) and enqueues
    /// the resulting absolute flag state for `OpQueueProcessor` to mirror to
    /// the server. Returns `false` (no-op) if the message doesn't exist or
    /// every row involved is already `\Seen` — the caller decides whether a
    /// replay attempt is worth making from that.
    ///
    /// 実機報告「Gmail のメールを既読にしてアーカイブしたのに、アーカイブ
    /// 側のスレッドに未読ドットが残る」の修正: この関数は以前、代表行 1 行
    /// しか書いていなかった。Gmail は同じメールが INBOX 行と All Mail 行の
    /// 2 行になるので、INBOX 行だけ既読にすると All Mail 行は未読のまま残る。
    /// `GmailArchiveFilter.excludeUnarchivedSQL` が「INBOX にも居る All Mail
    /// 行」を未読集計から外している間は見えないが、アーカイブで INBOX 行が
    /// 消えた瞬間に除外条件が外れ、未読 1 件として顕在化していた。
    /// 本文を開いたときの自動既読と、設定「アーカイブ時に既読にする」
    /// (`MessageRemoval.commit`) がどちらもこの関数を通るので、まさに
    /// 「開いてアーカイブする」操作で必ず踏む経路だった。
    ///
    /// 兄弟行への伝播をここに書き足すのではなく `MessagePinReadState
    /// .applyReadState` へ委譲しているのは、兄弟解決・`didWrite` による op
    /// 発行判断・`isPendingRelocation` スキップ・集約再計算の 4 点セットが
    /// 既にあちらに揃っているため。複製すると `applyPinState` で一度踏んだ
    /// 非対称バグ (代表行が目的の状態でも兄弟行がズレていれば処理を続ける、
    /// という判断) を既読側で作り直す余地が残る。
    @discardableResult
    public static func markSeen(messageId: Int64, accountId: String, db: Database) throws -> Bool {
        guard let record = try MessageRecord.fetchOne(db, key: messageId) else { return false }
        // `ThreadQuery.duplicateSiblings` はスレッド内を探すので、
        // `threadId` が無い行に兄弟は原理的に存在しない — その場合だけ
        // 単一行の従来経路を使う。
        guard let threadId = record.threadId else {
            return try markSeenWithoutThread(record: record, accountId: accountId, db: db)
        }
        return try MessagePinReadState.applyReadState(
            markingRead: true, messages: [record], threadId: threadId, accountId: accountId, db: db
        )
    }

    private static func markSeenWithoutThread(
        record: MessageRecord, accountId: String, db: Database
    ) throws -> Bool {
        var record = record
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
        // server's state and this optimistic mark-as-read can be silently
        // lost.
        //
        // **訂正 (2026-08-07)**: ここには以前「`createdAt`/`threadId`/
        // `isPinnedLocal`は resync の上書きから保護される」と書いてあったが
        // **事実と逆**だった — `EnvelopePersister.upsert`の`noOverwrite`列は
        // `createdAt`/`threadId`/`bodyState`/`snippet`/`detectedLanguage`で、
        // `isPinnedLocal`は毎回サーバーの`\Flagged`で上書きされる。この誤記の
        // せいで「メールの unpin が反映されない」の経路を一度見落とした。
        // フラグ・ピンを resync から守っているのは`noOverwrite`ではなく
        // `PendingOpTargets` (未送信 op がある UID は取り込まない) の方。 Narrow window in practice (the op queue usually replays,
        // and the destination syncs, within moments), not attempted here.
        if !record.isPendingRelocation, let mailbox = try MailboxRecord.fetchOne(db, key: record.mailboxId) {
            try OpQueue.enqueueSetFlags(
                accountId: accountId, mailboxId: record.mailboxId, uidValidity: mailbox.uidValidity,
                uids: [UInt32(record.uid)], flags: record.flags, db: db
            )
        }
        // `threadId` が無い行なので、再計算すべきスレッド集約も無い
        // (呼び出し元の `markSeen` がその条件で分岐している)。
        return true
    }
}
