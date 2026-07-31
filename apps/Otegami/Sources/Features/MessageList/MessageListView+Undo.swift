extension MessageListView {
    /// A destructive action (delete/archive, single-row swipe or bulk)
    /// whose local database write has **already happened** — see
    /// `commitDelete`/`commitArchive`'s doc comment for why this design
    /// commits immediately rather than delaying the write itself (a real
    /// data-loss bug the first version of this feature had). What
    /// `scheduleUndo` actually delays is the *network* replay attempt;
    /// `undo` reverses the local write and cancels the not-yet-replayed
    /// opQueue rows if the user taps "元に戻す" before that.
    struct PendingUndo {
        var threadIds: Set<Int64>
        var message: String
        var accountIds: Set<String>
        /// Task #163: `nil` for a blocked-action notice (nothing was
        /// actually removed, so there's nothing to reverse) — see
        /// `showArchiveBlockedByPinNotice()`'s doc comment.
        var undo: (() async -> Void)?
    }

    /// Shows an `UndoToast` for `Self.undoWindow`, after which the already-
    /// queued opQueue rows are allowed to actually replay to the server
    /// (`replayOpQueueSoon`) — see `commitDelete`/`commitArchive`'s doc
    /// comment for why the local write driving what's actually visible on
    /// screen has *already happened* by the time this is called, and only
    /// the network side is what this delays. `undo` reverses that local
    /// write and deletes the not-yet-replayed opQueue rows if the user taps
    /// "元に戻す" (`undoPending()`) before the window elapses; if replay
    /// already won the race (e.g. the account's IDLE loop or a manual
    /// refresh replayed it independently), `undo`'s opQueue-row deletion is
    /// simply a no-op (the rows are already gone) and only the local
    /// restore applies — a rare, acceptable edge case, not silent data
    /// corruption either way. Only one undo toast is shown at a time;
    /// scheduling a new one while an earlier one is still pending lets the
    /// earlier one's replay proceed immediately instead of waiting out its
    /// own window unseen.
    func scheduleUndo(threadIds: Set<Int64>, message: String, accountIds: Set<String>, undo: (() async -> Void)?) {
        pendingUndoTask?.cancel()
        if let previous = pendingUndo {
            Task { await replayOpQueueSoon(accountIds: previous.accountIds) }
        }
        pendingUndo = PendingUndo(threadIds: threadIds, message: message, accountIds: accountIds, undo: undo)
        notifyPendingUndoChanged()
        pendingUndoTask = Task {
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            pendingUndo = nil
            notifyPendingUndoChanged()
            await replayOpQueueSoon(accountIds: accountIds)
        }
    }

    /// Task #108: reports the current `pendingUndo` (or its absence) to
    /// `onPendingUndoChanged` — called from every site that mutates
    /// `pendingUndo` (`scheduleUndo`'s two writes, `undoPending()`, and the
    /// `scenePhase` backstop below) so a parent rendering the toast
    /// externally (`suppressInternalUndoToast`'s doc comment) never sees a
    /// stale value.
    func notifyPendingUndoChanged() {
        guard let pendingUndo else {
            onPendingUndoChanged(nil)
            return
        }
        onPendingUndoChanged(UndoToastPayload(message: pendingUndo.message, onUndo: undoButtonAction(for: pendingUndo)))
    }

    private func undoPending() {
        pendingUndoTask?.cancel()
        guard let pendingUndo, let undo = pendingUndo.undo else { return }
        self.pendingUndo = nil
        notifyPendingUndoChanged()
        Task { await undo() }
    }

    /// Task #163: `UndoToast`/`UndoToastPayload`'s `onUndo` for a given
    /// `PendingUndo` — `nil` (no button) for a blocked-action notice
    /// (`pending.undo == nil`), `undoPending` otherwise. Extracted into its
    /// own explicitly-typed function rather than an inline ternary at
    /// either call site — see `AccountDigestView.undoButtonAction(for:)`'s
    /// identical doc comment for why (a Swift compiler crash the inline
    /// form triggered inside `body`'s `some View` expression).
    func undoButtonAction(for pending: PendingUndo) -> (() -> Void)? {
        guard pending.undo != nil else { return nil }
        return undoPending
    }

    /// Task #163 (実機フィードバック「ピン留めされたメールはアーカイブできない
    /// ようにしてほしい」): shown when `SyncEngine.MessageRemoval.commit(_:
    /// summary:accountId:db:)` throws `MessageRemoval.ArchiveGuardError
    /// .pinned` — reuses `scheduleUndo`'s exact timer/external-render
    /// plumbing (`suppressInternalUndoToast`'s doc comment) with an empty
    /// `threadIds`/`accountIds` and a `nil` `undo`, so it renders as the same
    /// toast shell with no "元に戻す" button (`UndoToast`'s doc comment) and
    /// no opQueue replay to schedule — nothing was actually removed.
    func showArchiveBlockedByPinNotice() {
        scheduleUndo(threadIds: [], message: "ピン留め中のためアーカイブできません", accountIds: [], undo: nil)
    }
}
