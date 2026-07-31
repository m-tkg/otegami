import Foundation
import OtegamiStore
import SyncEngine

extension MessageListView {
    func enterSelectionMode(startingWith threadId: Int64) {
        guard !isSelecting else { return }
        isSelecting = true
        selectedThreadIds = [threadId]
        onSelectionModeChanged(true)
    }

    func exitSelectionMode() {
        guard isSelecting else { return }
        isSelecting = false
        selectedThreadIds = []
        onSelectionModeChanged(false)
    }

    func toggleSelection(_ threadId: Int64) {
        if selectedThreadIds.contains(threadId) {
            selectedThreadIds.remove(threadId)
        } else {
            selectedThreadIds.insert(threadId)
        }
    }

    var isAllVisibleSelected: Bool {
        let visibleIds = Set(displayedSummaries.compactMap(\.thread.id))
        return !visibleIds.isEmpty && visibleIds.isSubset(of: selectedThreadIds)
    }

    func toggleSelectAll() {
        let visibleIds = displayedSummaries.compactMap(\.thread.id)
        if isAllVisibleSelected {
            selectedThreadIds.subtract(visibleIds)
        } else {
            selectedThreadIds.formUnion(visibleIds)
        }
    }

    private func selectedTargets() -> [ThreadSummary] {
        let base = isSearchActive ? searchResults : summaries
        return base.filter { summary in
            guard let threadId = summary.thread.id else { return false }
            return selectedThreadIds.contains(threadId)
        }
    }

    func markSelectedAsRead() {
        let targets = selectedTargets()
        exitSelectionMode()
        Task {
            for summary in targets {
                await applyReadState(summary, markingRead: true)
            }
        }
    }

    /// Bulk "移動" — see `selectionBottomBar`'s doc comment for why this is
    /// scoped to "アーカイブへ移動" rather than an arbitrary destination
    /// picker. Each target thread's messages are moved (deleted locally,
    /// `move` op enqueued) immediately, same as the swipe row's own
    /// `archiveThread(_:)` — see `commitArchive`'s doc comment for why this
    /// commits right away rather than waiting out the undo window first.
    func archiveSelected() {
        let targets = selectedTargets()
        let ids = selectedThreadIds
        let accountIds = Set(targets.map(\.thread.accountId))
        exitSelectionMode()
        Task {
            var snapshots: [MessageRemoval.Snapshot] = []
            for summary in targets {
                if let snapshot = await commitArchive(summary) { snapshots.append(snapshot) }
            }
            guard !snapshots.isEmpty else { return }
            scheduleUndo(threadIds: ids, message: "\(ids.count)件のスレッドをアーカイブしました", accountIds: accountIds) {
                for snapshot in snapshots { await undoRemoval(snapshot) }
            }
        }
    }

    func deleteSelected() {
        let targets = selectedTargets()
        let ids = selectedThreadIds
        let accountIds = Set(targets.map(\.thread.accountId))
        exitSelectionMode()
        Task {
            var snapshots: [MessageRemoval.Snapshot] = []
            for summary in targets {
                if let snapshot = await commitDelete(summary) { snapshots.append(snapshot) }
            }
            guard !snapshots.isEmpty else { return }
            scheduleUndo(threadIds: ids, message: "\(ids.count)件のスレッドを削除しました", accountIds: accountIds) {
                for snapshot in snapshots { await undoRemoval(snapshot) }
            }
        }
    }
}
