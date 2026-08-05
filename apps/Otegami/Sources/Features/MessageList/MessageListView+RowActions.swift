import Foundation
import GRDB
import OtegamiCore
import OtegamiStore
import SyncEngine

extension MessageListView {
    /// Toggles every message in the thread to the opposite of the thread's
    /// current unread state — the swipe row's own single-thread action.
    /// `applyReadState(_:markingRead:)` below is the shared implementation
    /// bulk "既読に" also uses (forcing `markingRead: true` regardless of
    /// each thread's current state, rather than toggling).
    func toggleRead(_ summary: ThreadSummary) {
        let markingRead = summary.thread.unreadCount > 0
        Task {
            await applyReadState(summary, markingRead: markingRead)
        }
    }

    /// Enqueues an absolute `setFlags` op per affected message (plan: "全
    /// メッセージへ適用、opQueue 経由") and makes a best-effort replay attempt
    /// right away. Shared by the swipe row's `toggleRead(_:)` and bulk
    /// selection's "既読に" button.
    func applyReadState(_ summary: ThreadSummary, markingRead: Bool) async {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        do {
            try await environment.database.dbWriter.write { db in
                let messages = try ThreadQuery.actionTargets(for: summary, db: db)
                try MessagePinReadState.applyReadState(
                    markingRead: markingRead, messages: messages, threadId: threadId, accountId: accountId, db: db
                )
            }
            await replayOpQueueSoon(accountId: accountId)
        } catch {
            // Best-effort: the row simply doesn't update if this fails.
        }
    }

    /// D8/E9's swipe/context-menu "ピン留め" action — toggles every message
    /// in the thread to the opposite of the thread's current pinned state
    /// (`summary.thread.isPinned`, the OR-aggregate over its messages —
    /// `AppDatabase`'s v16 migration doc comment). Pinning every message in
    /// the thread together (rather than, say, just the row's own
    /// `latestMessage`) mirrors `toggleRead(_:)`/`archiveThread(_:)`'s
    /// existing "act on the whole thread" convention, and keeps pin/unpin
    /// symmetric: pinning then immediately unpinning the same row returns
    /// every message to exactly the state it started in, regardless of how
    /// many were already individually pinned.
    func togglePin(_ summary: ThreadSummary) {
        let pinning = !summary.thread.isPinned
        Task { await applyPinState(summary, pinning: pinning) }
    }

    /// No undo toast (unlike delete/archive) — pinning never removes a row
    /// from the list, it only reorders it, so the action is already
    /// trivially reversible with one more tap on the same button.
    private func applyPinState(_ summary: ThreadSummary, pinning: Bool) async {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        do {
            try await environment.database.dbWriter.write { db in
                let messages = try ThreadQuery.actionTargets(for: summary, db: db)
                try MessagePinReadState.applyPinState(
                    pinning: pinning, messages: messages, threadId: threadId, accountId: accountId, db: db
                )
            }
            await replayOpQueueSoon(accountId: accountId)
        } catch {
            // Best-effort, matching every other opQueue-enqueuing path in
            // this file.
        }
    }

    /// D8「迷惑メールにする」— mirrors `archiveThread(_:)`/`commitArchive(_:)`'s
    /// shape exactly, just moving to the account's Junk-role mailbox at
    /// *replay* time (`OpQueue.enqueueJunk`, resolved/self-healed by
    /// `OpQueueProcessor.resolveOrCreateJunkMailbox` the same way `delete`
    /// resolves Trash) rather than a pre-resolved local Archive mailbox id.
    func junkThread(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        Task {
            guard let snapshot = await commitJunk(summary) else { return }
            scheduleUndo(threadIds: [threadId], message: "\(undoNoun(for: summary))を迷惑メールにしました", accountIds: [accountId]) {
                await undoRemoval(snapshot)
            }
        }
    }

    /// 実機フィードバック第3弾 (A): the undo toast's noun — "スレッド" for a
    /// grouped-mode row (unchanged wording) vs. "メール" for a flat-mode row,
    /// matching `ThreadQuery.actionTargets(for:db:)`'s equally narrowed
    /// scope (see its doc comment) so the toast text never overstates what
    /// was actually touched.
    private func undoNoun(for summary: ThreadSummary) -> String {
        summary.singleMessageId != nil ? "メール" : "スレッド"
    }

    /// `commitArchive`'s `.junk` counterpart — see its doc comment.
    private func commitJunk(_ summary: ThreadSummary) async -> MessageRemoval.Snapshot? {
        do {
            guard let snapshot = try await environment.database.dbWriter.write({ db in
                try MessageRemoval.commit(.junk, summary: summary, accountId: summary.thread.accountId, db: db)
            }) else { return nil }
            if isSearchActive {
                searchResults.removeAll { $0.id == summary.id }
            }
            return snapshot
        } catch {
            return nil
        }
    }

    /// The swipe row's single-thread archive action — commits immediately
    /// (see `MessageRemoval.commit(_:summary:accountId:db:)`'s doc comment
    /// in `SyncEngine`), then hands the resulting snapshot to
    /// `scheduleUndo`.
    func archiveThread(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        Task {
            guard let snapshot = await commitArchive(summary) else { return }
            scheduleUndo(threadIds: [threadId], message: "\(undoNoun(for: summary))をアーカイブしました", accountIds: [accountId]) {
                await undoRemoval(snapshot)
            }
        }
    }

    /// Thin app-target wrapper around `SyncEngine.MessageRemoval.commit(_:
    /// summary:accountId:db:)` — the actual local-DB mutation is `SyncEngine`
    /// code now (unit-tested there without a SwiftUI host); this just wires
    /// it to `environment.database.dbWriter` and keeps `searchResults` in
    /// sync (a one-shot array, not a live `ValueObservation` like
    /// `summaries` — the normal list picks up a removal automatically, but
    /// a search-mode row needs this explicit nudge or the just-removed
    /// thread would keep showing until the next debounced re-search).
    func commitArchive(_ summary: ThreadSummary) async -> MessageRemoval.Snapshot? {
        do {
            guard let snapshot = try await environment.database.dbWriter.write({ db in
                try MessageRemoval.commit(
                    .archive, summary: summary, accountId: summary.thread.accountId, db: db,
                    markSeenOnArchive: ArchiveActionSettingsStore.markAsReadOnArchive
                )
            }) else { return nil }
            if isSearchActive {
                searchResults.removeAll { $0.id == summary.id }
            }
            return snapshot
        } catch is MessageRemoval.ArchiveGuardError {
            // Task #163: pinned — `archiveThread(_:)`'s swipe already
            // pre-checks this (`MessageListRow.commitReveal`'s pinned guard)
            // to skip the exit-slide animation, but this catch is still the
            // one place that actually blocks *every* archive path (the
            // toolbar/context-menu row action on macOS has no such
            // pre-check) — see `MessageRemoval.ArchiveGuardError`'s doc
            // comment.
            showArchiveBlockedByPinNotice()
            return nil
        } catch {
            // Best-effort, matching every other opQueue-enqueuing path in
            // this file.
            return nil
        }
    }

    /// Task #87 (1): "アーカイブ解除" — the archive view's swipe/context-menu
    /// row action. Mirrors `archiveThread(_:)`/`commitArchive(_:)` exactly
    /// (see their doc comments); only reached when `MessageListRow
    /// .isArchiveView` is `true`, so every `summary` this is ever called
    /// with is already an archived thread. Undo (`undoRemoval`) reverses
    /// this exactly like it reverses an archive/delete/junk — it just
    /// re-inserts the removed row(s) and cancels the not-yet-replayed
    /// `.unarchive` opQueue rows, which in effect re-archives.
    func unarchiveThread(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        Task {
            guard let snapshot = await commitUnarchive(summary) else { return }
            scheduleUndo(threadIds: [threadId], message: "\(undoNoun(for: summary))のアーカイブを解除しました", accountIds: [accountId]) {
                await undoRemoval(snapshot)
            }
        }
    }

    /// `commitArchive`'s `.unarchive` counterpart — see its doc comment.
    private func commitUnarchive(_ summary: ThreadSummary) async -> MessageRemoval.Snapshot? {
        do {
            guard let snapshot = try await environment.database.dbWriter.write({ db in
                try MessageRemoval.commit(.unarchive, summary: summary, accountId: summary.thread.accountId, db: db)
            }) else { return nil }
            if isSearchActive {
                searchResults.removeAll { $0.id == summary.id }
            }
            return snapshot
        } catch {
            // Best-effort, matching every other opQueue-enqueuing path in
            // this file.
            return nil
        }
    }

    /// The swipe row's single-thread delete action — commits immediately
    /// (see `commitArchive`'s doc comment; `commitDelete` is its `.delete`
    /// counterpart), then hands the resulting snapshot to `scheduleUndo`.
    func deleteThread(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        Task {
            guard let snapshot = await commitDelete(summary) else { return }
            scheduleUndo(threadIds: [threadId], message: "\(undoNoun(for: summary))を削除しました", accountIds: [accountId]) {
                await undoRemoval(snapshot)
            }
        }
    }

    /// `commitArchive`'s `.delete` counterpart — see its doc comment.
    func commitDelete(_ summary: ThreadSummary) async -> MessageRemoval.Snapshot? {
        do {
            guard let snapshot = try await environment.database.dbWriter.write({ db in
                try MessageRemoval.commit(.delete, summary: summary, accountId: summary.thread.accountId, db: db)
            }) else { return nil }
            if isSearchActive {
                searchResults.removeAll { $0.id == summary.id }
            }
            return snapshot
        } catch {
            // Best-effort: whatever's left stays if this fails; the
            // swipe can be retried.
            return nil
        }
    }

    /// Reverses one `commitDelete`/`commitArchive` call — thin wrapper
    /// around `SyncEngine.MessageRemoval.undo(_:db:)`; see that method's
    /// doc comment for the thread-before-messages ordering this restores
    /// and why it matters. Best-effort, matching every other
    /// opQueue-enqueuing/db-mutating path in this file — a failure here
    /// just leaves the delete/archive applied, same as if "元に戻す" had
    /// never been tapped.
    func undoRemoval(_ snapshot: MessageRemoval.Snapshot) async {
        do {
            try await environment.database.dbWriter.write { db in
                try MessageRemoval.undo(snapshot, db: db)
            }
        } catch {
            // Best-effort — see doc comment above.
        }
    }
}
