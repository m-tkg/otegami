import Foundation
import SwiftUI
import GRDB
import OtegamiCore
import OtegamiStore
import SyncEngine

// MARK: - 新画面構成 (3): スレッド操作 ("…" メニュー)
//
// `MessageListView`'s equivalent row actions (`toggleRead`/
// `archiveThread`/`junkThread`/`togglePin`/`deleteThread`) are tightly
// coupled to that view's own undo-toast/search-results state
// (`scheduleUndo`, `searchResults`), which this screen doesn't have —
// rather than force this view to depend on that state just to reuse
// the logic, these are independent, standalone implementations that
// read `ThreadQuery`/write through `OpQueue` the exact same way, the
// same "can't drift in behavior even though the code isn't literally
// shared" tradeoff `RootView.deleteSelectedThread()` (macOS ⌘⌫) already
// makes for the identical reason. Unlike `MessageListView`'s swipe
// actions, none of these show an undo toast here — this screen instead
// pops back to the list (`dismiss()`) once the thread's messages are
// gone, which is itself an obvious, immediate confirmation the action
// happened.

extension ThreadDetailView {
    func toggleMute() {
        let muted = !isThreadMuted
        isThreadMuted = muted
        Task {
            try? await environment.database.dbWriter.write { db in
                try ThreadQuery.setMuted(threadId: threadId, muted: muted, db: db)
            }
        }
    }

    func togglePin() {
        let pinning = !isThreadPinned
        isThreadPinned = pinning
        Task { await applyPinState(pinning: pinning) }
    }

    private func applyPinState(pinning: Bool) async {
        guard let accountId else { return }
        do {
            try await environment.database.dbWriter.write { db in
                let messages = try Self.targetMessageRecords(threadId: threadId, singleMessageId: singleMessageId, db: db)
                try MessagePinReadState.applyPinState(
                    pinning: pinning, messages: messages, threadId: threadId, accountId: accountId, db: db
                )
            }
            await replaySoon()
        } catch {
            // Best-effort — the toolbar's pin state just doesn't flip.
        }
    }

    func markUnread() {
        Task { await applyReadState(markingRead: false) }
    }

    private func applyReadState(markingRead: Bool) async {
        guard let accountId else { return }
        do {
            try await environment.database.dbWriter.write { db in
                let messages = try Self.targetMessageRecords(threadId: threadId, singleMessageId: singleMessageId, db: db)
                try MessagePinReadState.applyReadState(
                    markingRead: markingRead, messages: messages, threadId: threadId, accountId: accountId, db: db
                )
            }
            await replaySoon()
        } catch {
            // Best-effort, matching every other opQueue-enqueuing path.
        }
    }

    /// Task #127 (実機報告フォローアップ、Task #120の follow-up):
    /// archive/junk/delete used to be an independent,
    /// hand-rolled enqueue-then-delete implementation here — unlike
    /// `MessageListView`/`AccountDigestView`'s row actions, it never called
    /// `SyncEngine.MessageRemoval.commit(_:summary:accountId:db:)`, so it
    /// never got that method's Task #120 "pending relocation" behavior
    /// (relocate the row into the already-known-locally destination mailbox
    /// immediately, with a negative placeholder UID, instead of just
    /// deleting it and waiting for that mailbox's own next sync to discover
    /// the move) — archiving/deleting/junking straight from the message
    /// body screen wouldn't show up in Archive/Trash/Junk until the next
    /// pull-to-refresh, even though the exact same action from the list
    /// (swipe) or the account digest already relocated instantly. Routing
    /// through `MessageRemoval.commit` here closes that gap by construction
    /// — any future change to that shared commit logic (relocation,
    /// Gmail's no-Archive-mailbox special case, etc.) now automatically
    /// applies to this screen too, instead of needing to be duplicated a
    /// third time.
    ///
    /// Builds the same `ThreadSummary` shape `OtegamiStore.ThreadQuery
    /// .actionTargets(for:db:)` expects: `ThreadSummary(flatMessage:
    /// accountId:)` when `singleMessageId` is set (mirrors
    /// `targetMessageRecords(threadId:singleMessageId:db:)`'s existing
    /// single-message branch, used by `applyPinState`/`applyReadState`
    /// above), or a plain `ThreadSummary(thread:latestMessage:)` for a
    /// grouped-mode thread (`latestMessage` is `nil` here rather than
    /// re-fetching it — `commit`/`actionTargets` only ever read
    /// `summary.thread.id`/`summary.singleMessageId` for a `nil`-
    /// `flatMessageId` summary, never `latestMessage` itself).
    /// Task #165: relaxed from `private` to internal (same module, no
    /// behavior change) so `RootView`'s new ⌘E/⇧⌘U menu-command handlers
    /// (`archiveSelectedThread()`/`toggleReadSelectedThread()`) can build the
    /// same `ThreadSummary` adapter this view's own `commitRemoval(_:)`/
    /// `applyReadState(markingRead:)`-equivalent logic needs, instead of
    /// duplicating this construction a third time.
    nonisolated static func threadSummary(threadId: Int64, singleMessageId: Int64?, accountId: String, db: Database) throws -> ThreadSummary? {
        guard let thread = try ThreadRecord.fetchOne(db, key: threadId) else { return nil }
        if let singleMessageId {
            guard let message = try MessageRecord.fetchOne(db, key: singleMessageId) else { return nil }
            var summary = ThreadSummary(flatMessage: message, accountId: accountId)
            // Task #151: not read by `MessageRemoval.commit`/`actionTargets`
            // today, but computed anyway so this adapter summary doesn't
            // silently carry a stale `false` if a future caller starts
            // reading it.
            summary.isArchived = try ThreadQuery.isMessageArchived(messageId: singleMessageId, db: db)
            return summary
        }
        var summary = ThreadSummary(thread: thread, latestMessage: nil)
        summary.isArchived = try ThreadQuery.isThreadArchived(threadId: threadId, db: db)
        return summary
    }

    /// Shared body for `archiveThread()`/`junkThread()`/`deleteThread()` —
    /// see `threadSummary(threadId:singleMessageId:accountId:db:)`'s doc
    /// comment for why this now delegates the actual removal to
    /// `MessageRemoval.commit` instead of a hand-rolled per-`kind`
    /// enqueue-then-delete. `commit` returns `nil` when nothing was
    /// actually removed (e.g. re-archiving an already-archived message) —
    /// `notifyThreadRemoved()`/`replaySoon()` are skipped entirely in that
    /// case, matching `archiveThread()`'s pre-existing `didArchiveAny`
    /// guard (junk/delete previously had no such guard; unifying on
    /// `commit`'s own nil-check gives them the same, arguably more correct,
    /// behavior for free).
    private func commitRemoval(_ kind: MessageRemoval.Kind) async {
        guard let accountId else { return }
        do {
            let removed = try await environment.database.dbWriter.write { db -> Bool in
                guard let summary = try Self.threadSummary(threadId: threadId, singleMessageId: singleMessageId, accountId: accountId, db: db) else {
                    return false
                }
                return try MessageRemoval.commit(kind, summary: summary, accountId: accountId, db: db) != nil
            }
            guard removed else { return }
            // 実機報告 (数秒「メッセージが見つかりません」が見えてから一覧に
            // 戻る): ここが元は `await replaySoon()` の**後**に
            // `notifyThreadRemoved()` を呼んでいた。ローカル DB からの削除
            // (今は `MessageRemoval.commit`) は `dbWriter.write` が返った
            // 時点で確定済みで、その瞬間 `messages` を購読している
            // `ThreadQuery.messagesObservation`/単一メッセージ observation
            // が空を配信し、`body` の `ContentUnavailableView` (空状態
            // placeholder) がすぐさま描画される。`notifyThreadRemoved()`
            // (→ `MailScreenView.handleThreadRemoved` が次のスレッドを開く
            // か pop する) が `replaySoon()` というネットワーク I/O
            // (opQueue の replay) の完了を待ってからでないと呼ばれなかった
            // ため、その間の数秒間だけ placeholder が見え続けていた。
            // `notifyThreadRemoved()` はローカル DB の反映だけで完結する
            // 処理で `replaySoon()` の結果に依存しないので、先に呼んで
            // 即座に遷移させ、`replaySoon()` はその後 (同じ `Task` の続き
            // として、遷移をブロックせずに) 実行する — 空状態 placeholder
            // は自分の操作では実質見えなくなり、他クライアントでの削除
            // などローカル操作を経由しない消滅のフォールバックとしてのみ
            // 残る。Task #127: この順序 (`notifyThreadRemoved()` →
            // `replaySoon()`) は archive/junk/delete の3操作全てで共有する
            // このヘルパー1箇所にしか存在しないので、以後崩れようがない。
            notifyThreadRemoved()
            await replaySoon()
        } catch is MessageRemoval.ArchiveGuardError {
            // Task #163: pinned — refused by `MessageRemoval.commit` itself
            // (the shared guard every archive path routes through), so
            // nothing was removed and there's nothing to notify/replay for.
            showPinnedArchiveNotice()
        } catch {
            // Best-effort — the thread just stays if this fails.
        }
    }

    /// Task #163: auto-dismissing, undo-less notice — see
    /// `pinnedArchiveNotice`'s doc comment for why this screen needs one at
    /// all when every other action here has none.
    private func showPinnedArchiveNotice() {
        pinnedArchiveNoticeTask?.cancel()
        pinnedArchiveNotice = "ピン留め中のためアーカイブできません"
        pinnedArchiveNoticeTask = Task {
            try? await Task.sleep(for: Self.pinnedArchiveNoticeWindow)
            guard !Task.isCancelled else { return }
            pinnedArchiveNotice = nil
        }
    }

    /// Task #184: routes to `.unarchive` instead of `.archive` whenever
    /// `isThreadArchived` — the same single entry point `footerToolbar`'s
    /// archive slot and every per-row macOS context menu already call, so
    /// neither surface needs its own branch (`archiveButton`'s/
    /// `contextMenuContent`'s doc comments only need to swap the *label/
    /// icon*, not duplicate this decision).
    func archiveThread() {
        Task { await commitRemoval(isThreadArchived ? .unarchive : .archive) }
    }

    func junkThread() {
        Task { await commitRemoval(.junk) }
    }

    func deleteThread() {
        Task { await commitRemoval(.delete) }
    }

    /// 実機フィードバック第3弾 (A): what "…" menu's archive/junk/delete
    /// operations should actually touch — every message in `threadId` for
    /// a grouped-mode open (unchanged), or just `singleMessageId` for a
    /// flat-mode one. Mirrors `OtegamiStore.ThreadQuery.actionTargets(for:
    /// db:)`'s exact same narrowing for `MessageListView`'s row actions —
    /// see that method's doc comment for the real-device report both fix.
    ///
    /// `nonisolated static`, taking `threadId`/`singleMessageId` as plain
    /// `Int64`/`Int64?` parameters rather than reading `self` — an
    /// *instance* method called from inside a `dbWriter.write { db in ... }`
    /// closure implicitly captures `self` (a non-`Sendable` `View`) to
    /// resolve the call, which Swift 6 strict concurrency flags as "sending
    /// 'db' risks causing data races". Plain `static` alone isn't enough
    /// either — every member of a `View`-conforming type, `static` methods
    /// included, is implicitly `@MainActor`-isolated (confirmed by `make
    /// mac`'s error switching from blaming `self` to blaming a `static`
    /// method call once this was first made `static`, then finally
    /// compiling once `nonisolated` was added), while the closure passed to
    /// `dbWriter.write` runs task-isolated, not main-actor-isolated — the
    /// exact mismatch "sending 'db' risks causing data races" describes.
    private nonisolated static func targetMessageRecords(threadId: Int64, singleMessageId: Int64?, db: Database) throws -> [MessageRecord] {
        if let singleMessageId {
            return try MessageRecord.fetchOne(db, key: singleMessageId).map { [$0] } ?? []
        }
        return try ThreadQuery.messages(threadId: threadId, db: db)
    }

    /// See `onThreadRemoved`'s doc comment: reports the removal upward when
    /// wired, falling back to this screen's own pre-existing `dismiss()`
    /// otherwise.
    ///
    /// 実機フィードバック第3弾 (A): always just `dismiss()`s for a flat-mode
    /// open (`isFlatModeEntry`), never calling `onThreadRemoved` even when
    /// it's wired — `MessagePostActionSettingsStore.nextThreadId`'s「次の
    /// メールを開く」resolves against `currentThreadOrder`, an ordered list
    /// of *real* thread ids (`MessageListView.onSummariesChanged`), not
    /// per-message ids; the caller has no way to know *which* message within
    /// the resolved next thread id should open in single-message mode, so
    /// honoring 「次のメールを開く」 here would silently reopen the right
    /// thread but in the wrong (full accordion) mode. Falling back to "戻る"
    /// unconditionally for this entry point is a deliberate, documented
    /// scope limit rather than an attempt to thread per-message ordering
    /// through every caller for a setting whose default is already
    /// "メール一覧に戻る".
    ///
    /// Checks `isFlatModeEntry`, not `singleMessageId == nil` — see that
    /// property's doc comment: the two are functionally equivalent again
    /// today (Task #136 reverted the brief `ThreadSelectionView`-era window
    /// where they could disagree), but this still names the actual
    /// distinction that matters here rather than relying on that equivalence
    /// holding. A grouped-mode entry (a 1-message thread, or this view's own
    /// multi-message accordion) still very much wants 「次のメールを開く」
    /// to keep working — only a truly flat-mode (or flat search-result)
    /// entry has the "which message within the next thread" ambiguity this
    /// scope limit exists for.
    private func notifyThreadRemoved() {
        if let onThreadRemoved, !isFlatModeEntry {
            onThreadRemoved(threadId)
        } else {
            dismiss()
        }
    }

    private func replaySoon() async {
        guard let accountId, let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
        guard let auth = try? await environment.auth(for: account) else { return }
        _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
    }
}
