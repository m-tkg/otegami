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
        // macOS は「選択モード」という状態を持たない — 一覧は常に
        // `List(selection:)` で選択でき (`messageListCore`)、`isSelecting`
        // は一度も true にならない。一括操作の後始末として選択だけは
        // 落としたいので、iOS の `guard isSelecting` より手前で処理する。
        #if os(macOS)
        selectedThreadIds = []
        #endif
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

    /// (`private`から internal へ — macOS のコンテキストメニュー
    /// (`MessageListSelectionMenu`) が、選択中スレッドの状態からラベルを
    /// 出し分けるために読む。)
    func selectedTargets() -> [ThreadSummary] {
        let base = isSearchActive ? searchResults : summaries
        return base.filter { summary in
            guard let threadId = summary.thread.id else { return false }
            return selectedThreadIds.contains(threadId)
        }
    }

    /// ユーザー要望 (2026-08-08「マウスなどで複数選択して、右クリックで
    /// アーカイブや既読化、ピン留めできるようにして」) — macOS の複数選択
    /// コンテキストメニュー用。`markSelectedAsRead()`と対になる未読化で、
    /// あちらと同じく現在の状態を見てトグルするのではなく全件を未読へ
    /// 揃える (混在した集合の一括トグルは結果が直感的でない、という
    /// `selectionBottomBar`「既読に」からの既存判断を踏襲)。
    func markSelectedAsUnread() {
        let targets = selectedTargets()
        exitSelectionMode()
        Task {
            for summary in targets {
                await applyReadState(summary, markingRead: false)
            }
        }
    }

    /// 選択中スレッドをまとめてピン留め/解除する。`togglePin(_:)`と同じく
    /// Undo トーストは出さない (行が消えないので、もう一度実行すれば戻る)
    /// — `applyPinState`の doc comment 参照。
    ///
    /// 選択を落とさない点だけ他の一括操作と異なる: アーカイブ/削除と違って
    /// 行はその場に残るので、ピン留めした直後に同じ選択へ続けて別の操作を
    /// かけられる方が自然。
    func applyPinToSelected(pinning: Bool) {
        let targets = selectedTargets()
        Task {
            for summary in targets {
                await applyPinState(summary, pinning: pinning)
            }
        }
    }

    /// `ids`に対応する表示中スレッド — macOS のコンテキストメニューは
    /// `selectedThreadIds`ではなく`.contextMenu(forSelectionType:)`が渡す
    /// 集合を正とする (選択外の行を右クリックした場合、SwiftUI はその行
    /// だけを`ids`に載せてメニューを開く)。
    func summaries(for ids: Set<Int64>) -> [ThreadSummary] {
        let base = isSearchActive ? searchResults : summaries
        return base.filter { summary in
            guard let threadId = summary.thread.id else { return false }
            return ids.contains(threadId)
        }
    }

    /// コンテキストメニューの各項目の共通ラッパー — 既存の一括操作
    /// (`markSelectedAsRead()`等) はどれも`selectedThreadIds`を読むので、
    /// 実行直前に右クリック対象の集合をそこへ移してから呼ぶ
    /// (`summaries(for:)`の doc comment 参照)。
    func runBulkAction(on ids: Set<Int64>, _ action: () -> Void) {
        selectedThreadIds = ids
        action()
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
            // 件数は選択数 (`ids.count`) ではなく実際に処理できた数
            // (`snapshots.count`) — ピン留めされたスレッドは
            // `commitArchive` が `ArchiveGuardError` を握って `nil` を返す
            // ので選択数とはズレる (macOS の⌘A→アーカイブで実際に踏んだ:
            // 17件選択・16件アーカイブなのに「17件」と出ていた)。
            scheduleUndo(threadIds: ids, message: "\(snapshots.count)件のスレッドをアーカイブしました", accountIds: accountIds) {
                for snapshot in snapshots { await undoRemoval(snapshot) }
            }
        }
    }

    /// `archiveSelected()`の「アーカイブ解除」版 — 一覧が
    /// `.unifiedRole(.archive)` (`isArchiveView`) のとき、macOS の複数選択
    /// コンテキストメニューがアーカイブの代わりにこちらを出す
    /// (`MessageListRow.archiveLabel`の単一行版と同じ出し分け)。
    func unarchiveSelected() {
        let targets = selectedTargets()
        let ids = selectedThreadIds
        let accountIds = Set(targets.map(\.thread.accountId))
        exitSelectionMode()
        Task {
            var snapshots: [MessageRemoval.Snapshot] = []
            for summary in targets {
                if let snapshot = await commitUnarchive(summary) { snapshots.append(snapshot) }
            }
            guard !snapshots.isEmpty else { return }
            scheduleUndo(threadIds: ids, message: "\(snapshots.count)件のスレッドのアーカイブを解除しました", accountIds: accountIds) {
                for snapshot in snapshots { await undoRemoval(snapshot) }
            }
        }
    }

    /// `archiveSelected()`の迷惑メール版 — macOS の複数選択コンテキスト
    /// メニュー用 (単一行メニューには以前から「迷惑メールにする」がある
    /// ので、複数選択でだけ落ちるのは不自然)。
    func junkSelected() {
        let targets = selectedTargets()
        let ids = selectedThreadIds
        let accountIds = Set(targets.map(\.thread.accountId))
        exitSelectionMode()
        Task {
            var snapshots: [MessageRemoval.Snapshot] = []
            for summary in targets {
                if let snapshot = await commitJunk(summary) { snapshots.append(snapshot) }
            }
            guard !snapshots.isEmpty else { return }
            scheduleUndo(threadIds: ids, message: "\(snapshots.count)件のスレッドを迷惑メールにしました", accountIds: accountIds) {
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
            scheduleUndo(threadIds: ids, message: "\(snapshots.count)件のスレッドを削除しました", accountIds: accountIds) {
                for snapshot in snapshots { await undoRemoval(snapshot) }
            }
        }
    }
}
