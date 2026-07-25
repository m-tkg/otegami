import SwiftUI
import GRDB
import GoogleOAuth
import OtegamiCore
import OtegamiStore
import SyncEngine
import MailTransport

/// The selected sidebar item's threads, newest-first (M4: thread rows, not
/// individual messages — plan: "MessageListView をスレッド単位表示に変更").
/// Works fully offline: it only ever reads from `AppDatabase`, either one
/// mailbox's threads (`SidebarSelection.mailbox`) or the cross-account
/// "すべての受信トレイ" unified inbox (`SidebarSelection.unifiedInbox`, plan:
/// "アカウント境界を跨いだスレッド結合はしない" — each row is still one
/// account's thread, just interleaved by date across accounts). Refreshing
/// (pull-to-refresh or the toolbar button) is what triggers `SyncCoordinator`
/// to talk to the server; with no network the list still renders whatever's
/// already stored.
///
/// Design-phase-2 (1a/1d/1g/1h): the platforms now diverge more than they
/// used to. macOS keeps everything from before this pass unchanged — its
/// own `.navigationTitle`, `.searchable` search bar (M7), and swipe/context
/// menu semantics. iOS drops `.navigationTitle`/`.searchable` from this view
/// entirely (the enclosing `MailTabView` owns the tappable folder-picker
/// title instead, and search moved to its own tab — `SearchTabView`) and
/// gains 1g's redesigned swipe actions, 1h's long-press bulk-selection mode,
/// and an undo toast for the two destructive bulk-capable actions (delete,
/// archive). Every macOS-only addition/removal below is behind `#if
/// os(macOS)`/`#if os(iOS)` so this stays one file rather than forking into
/// two near-duplicates.
struct MessageListView: View {
    @Environment(AppEnvironment.self) private var environment
    let selection: SidebarSelection
    /// 1a's account filter chips, iOS only: when `selection == .unifiedInbox`
    /// and this is non-`nil`, only that one account's inbox-role mailboxes
    /// are observed (the "仕事"/"個人"-style chip) instead of every account
    /// (the "全部" chip). `nil` on every macOS call site — that platform has
    /// no chip row at all (`CLAUDE.md`: 1a is iOS-only structure) — and
    /// `nil` also for iOS's own "全部" chip, so this parameter doesn't
    /// change `ThreadQuery.unifiedInboxSummariesObservation`'s existing
    /// accountIds-across-every-account behavior unless a caller opts in.
    var unifiedInboxAccountFilter: String? = nil
    // By id (`ThreadRecord` isn't `Hashable` in the `List(selection:)`
    // sense this project uses — see M2's doc note on why rows are plain
    // `Button`s instead). Set directly from a `Button` action per row; the
    // compact-width column push to `ThreadDetailView` once this changes is
    // driven by `RootView`'s `preferredCompactColumn` (macOS's
    // `NavigationSplitView`) or `MailTabView`'s own `.navigationDestination`
    // (iOS).
    @Binding var selectedThreadId: Int64?
    /// Called on *every* row tap, in addition to writing `selectedThreadId`
    /// directly — mirrors `SidebarView.onSelected`'s doc comment: a
    /// re-tap of the row for the thread that's already `selectedThreadId`
    /// (e.g. after popping back from `ThreadDetailView` via the system
    /// back button, then reopening the same thread) doesn't change the
    /// binding's value, so an `onChange(of: selectedThreadId)`-driven push
    /// of `preferredCompactColumn` never fires a second time
    /// (docs/verify.md, "メール本文 → 戻る → 一覧の「さっき見ていたスレッド」
    /// 行だけタップ不能"). `RootView`/`MailTabView` use this unconditional
    /// callback to force the column/push forward every time instead.
    var onThreadSelected: (Int64) -> Void = { _ in }
    /// 1h: fires whenever this view enters/exits bulk-selection mode, so an
    /// iOS-only enclosing `MailTabView` can hide its own toolbar (folder
    /// title button, compose button) while the selection nav/bottom bar
    /// below take over. Never called on macOS (no long-press gesture there
    /// to trigger it in the first place).
    var onSelectionModeChanged: (Bool) -> Void = { _ in }

    @State private var summaries: [ThreadSummary] = []
    @State private var isSyncing = false
    @State private var syncErrorMessage: String?

    // MARK: - Pagination (M10, docs/performance.md)

    /// How many threads `observeThreads()` currently requests — starts at
    /// `Self.pageStep` and grows by the same amount each time the last row
    /// scrolls into view (`loadMoreIfNeeded(currentItem:)`). Without this,
    /// a 100k-message mailbox's `ValueObservation` would fetch (and
    /// `ThreadQuery.summaries(forThreads:)` would N+1-query) every thread
    /// up front — see docs/performance.md's "改善1"/"改善3" for the
    /// measured cost of that. Reset to `Self.pageStep` whenever `selection`
    /// changes so switching mailboxes doesn't keep whatever page depth the
    /// previous mailbox had scrolled to.
    @State private var pageLimit = MessageListView.pageStep
    private static let pageStep = 200

    // MARK: - Search (M7, macOS only as of design-phase-2 — see this
    // type's doc comment)

    @State private var searchText = ""
    @State private var searchScope: SearchScopeOption = .all
    @State private var searchResults: [ThreadSummary] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    /// M10: bound to `.searchFocused` — see the modifier's usage site below
    /// for why (⌘⇧F's target, macOS only).
    @FocusState private var isSearchFieldFocused: Bool

    // MARK: - Bulk selection (1h, iOS only)

    @State private var isSelecting = false
    @State private var selectedThreadIds: Set<Int64> = []

    // MARK: - Undo (1h/1g: "即時反映＋Undo（トースト）")

    /// A destructive action (delete/archive, single-row swipe or bulk) that
    /// has already been applied to *this view's own displayed list*
    /// (`pendingRemovalThreadIds`, below) but not yet committed to the
    /// database/opQueue — see `scheduleUndo(threadIds:message:commit:)`'s
    /// doc comment for the full design.
    private struct PendingUndo {
        var threadIds: Set<Int64>
        var message: String
        var commit: () async -> Void
    }
    @State private var pendingUndo: PendingUndo?
    @State private var pendingUndoTask: Task<Void, Never>?
    /// Threads hidden from `displayedSummaries` while a delete/archive is
    /// "pending undo" — the underlying `message`/`thread` rows are still
    /// fully intact in the database until `pendingUndo`'s `commit` actually
    /// runs, so this is a *view-local* filter, not a real deletion.
    @State private var pendingRemovalThreadIds: Set<Int64> = []
    /// How long an undo toast stays up before its action actually commits.
    /// 5s matches the common "Gmail-style" undo window long enough to
    /// react to, short enough not to leave a destructive action feeling
    /// unfinished.
    private static let undoWindow: Duration = .seconds(5)

    /// Restarts the thread observation whenever the selection changes *or*
    /// the account list changes — the latter matters for the unified inbox:
    /// adding a second account (M4 verification scenario (c)) should widen
    /// which accounts' inbox threads it observes without needing a manual
    /// refresh or relaunch.
    private struct ObservationKey: Hashable {
        var selection: SidebarSelection
        var accountFilter: String?
        var accountIds: [String]
        var pageLimit: Int
    }

    /// Whitespace-only input (including the empty string right after
    /// `.searchable` clears) is "not searching" — the normal `summaries`
    /// list shows, exactly like before M7.
    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the `List` actually renders: search results while a query is
    /// active (macOS only — iOS never populates `searchText`, this view no
    /// longer hosts a search field there), the live `ThreadQuery`
    /// observation otherwise, with any thread still inside its undo window
    /// (`pendingRemovalThreadIds`) filtered out. Rows, `MessageListRow`,
    /// and every swipe/bulk action are shared between the search-results
    /// and normal-list cases — marking a search hit read or deleting it
    /// works exactly like it does from the normal list.
    private var displayedSummaries: [ThreadSummary] {
        let base = isSearchActive ? searchResults : summaries
        guard !pendingRemovalThreadIds.isEmpty else { return base }
        return base.filter { summary in
            guard let threadId = summary.thread.id else { return true }
            return !pendingRemovalThreadIds.contains(threadId)
        }
    }

    /// "現在のメールボックス" only means something with one specific mailbox
    /// selected; the unified inbox has no single mailbox to narrow to, so
    /// its scope picker only ever offers "すべて".
    private var availableScopes: [SearchScopeOption] {
        switch selection {
        case .mailbox: [.all, .currentMailbox]
        case .unifiedInbox: [.all]
        }
    }

    /// 1d: the account-color rail/trailing account label only mean
    /// something where a row could plausibly belong to more than one
    /// account — the true "全部" unified inbox. A single mailbox, or the
    /// unified inbox narrowed to one account via 1a's filter chip, already
    /// guarantees every visible row shares one account, so the accent would
    /// be redundant color noise (`docs/design-system.md` records this
    /// refinement over the handoff's plainer "統合受信トレイでは...").
    private var showsAccountAccent: Bool {
        guard case .unifiedInbox = selection else { return false }
        return unifiedInboxAccountFilter == nil
    }

    private var accountDisplayNames: [String: String] {
        Dictionary(uniqueKeysWithValues: environment.accounts.map { ($0.id, $0.displayName) })
    }

    var body: some View {
        List {
            ForEach(displayedSummaries) { summary in
                threadRow(for: summary)
            }
        }
        .accessibilityIdentifier("messageList.list")
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .overlay {
            if isSearchActive {
                if isSearching {
                    ProgressView("検索中…")
                        .accessibilityIdentifier("messageList.search.loading")
                } else if searchResults.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .accessibilityIdentifier("messageList.search.emptyState")
                }
            } else if summaries.isEmpty {
                ContentUnavailableView(
                    "メッセージがありません",
                    systemImage: "envelope",
                    description: Text(isSyncing ? "同期中…" : "再同期を試してください。")
                )
                .accessibilityIdentifier("messageList.emptyState")
            }
        }
        #if os(macOS)
        // No `.accessibilityIdentifier` chained after `.searchable` here —
        // doing so doesn't tag the search field with its own identifier
        // the way it would for a plain child view; it *replaces* whatever
        // identifier the preceding modifier chain already set on this same
        // `List` ("messageList.list", set above), which broke XCUITest's
        // ability to find the list at all (discovered running
        // `OtegamiM7SetupUITests`, back when this view was shared by both
        // platforms). `.searchable`'s system search bar is reliably the
        // only one on screen, so an XCUITest would locate it via
        // `app.searchFields.firstMatch` instead (`SearchUITestHelpers
        // .typeSearchQuery`) — moot for iOS now (no `.searchable` here at
        // all; see `SearchTabView`), still correct for macOS.
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "検索")
        // M10: ⌘⇧F (`OtegamiCommands`) — `.searchFocused` is the modifier
        // SwiftUI documents specifically for programmatically focusing the
        // field `.searchable` creates (there's no view identity to target
        // it with `@FocusState` the normal way, since `.searchable` doesn't
        // expose one).
        .searchFocused($isSearchFieldFocused)
        .focusedSceneValue(\.focusSearchAction, { isSearchFieldFocused = true })
        .searchScopes($searchScope) {
            ForEach(availableScopes) { scope in
                Text(scope.title)
                    .tag(scope)
                    .accessibilityIdentifier("messageList.search.scope.\(scope.rawValue)")
            }
        }
        .onChange(of: searchText) { _, _ in scheduleSearch() }
        .onChange(of: searchScope) { _, _ in scheduleSearch() }
        #endif
        .onChange(of: selection) { _, _ in
            if !availableScopes.contains(searchScope) { searchScope = .all }
            // M10 pagination: a fresh mailbox/unified-inbox selection
            // starts back at the first page — otherwise switching from a
            // mailbox someone had scrolled deep into to a brand-new one
            // would request (and wait on) that same deep page size again.
            pageLimit = Self.pageStep
            exitSelectionMode()
        }
        .toolbar {
            listToolbarContent
        }
        #if os(iOS)
        .refreshable { await refresh() }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
        #endif
        .overlay(alignment: .bottom) {
            if let pendingUndo {
                UndoToast(message: pendingUndo.message, onUndo: undoPending)
                    .animation(.default, value: pendingUndo.threadIds)
            }
        }
        .task(id: ObservationKey(selection: selection, accountFilter: unifiedInboxAccountFilter, accountIds: environment.accounts.map(\.id), pageLimit: pageLimit)) {
            await observeThreads()
        }
        .alert(
            "同期エラー",
            isPresented: Binding(
                get: { syncErrorMessage != nil },
                set: { if !$0 { syncErrorMessage = nil } }
            )
        ) {
            Button("OK") { syncErrorMessage = nil }
        } message: {
            Text(syncErrorMessage ?? "")
        }
    }

    /// The toolbar's whole content, split out of `body` — split for the same
    /// "keep each modifier-chain expression small" reason `docs/ci.md`
    /// documents everywhere else in this app, but also because it now
    /// branches on `isSelecting` (1h's swapped-out nav bar: キャンセル /
    /// "N件を選択中" / 全選択) in addition to the platform split the rest of
    /// `body` already has.
    @ToolbarContentBuilder
    private var listToolbarContent: some ToolbarContent {
        #if os(iOS)
        if isSelecting {
            ToolbarItem(placement: .cancellationAction) {
                Button("キャンセル") { exitSelectionMode() }
                    .accessibilityIdentifier("messageList.selection.cancelButton")
            }
            ToolbarItem(placement: .principal) {
                Text("\(selectedThreadIds.count)件を選択中")
                    .font(OtegamiFont.headline())
                    .accessibilityIdentifier("messageList.selection.countLabel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isAllVisibleSelected ? "選択解除" : "全選択") { toggleSelectAll() }
                    .accessibilityIdentifier("messageList.selection.selectAllButton")
            }
        } else {
            refreshToolbarItem
        }
        #else
        refreshToolbarItem
        #endif
    }

    private var refreshToolbarItem: some ToolbarContent {
        ToolbarItem {
            Button {
                Task { await refresh() }
            } label: {
                if isSyncing {
                    ProgressView()
                } else {
                    Label("再同期", systemImage: "arrow.clockwise")
                }
            }
            .accessibilityIdentifier("messageList.refreshButton")
            .disabled(isSyncing)
        }
    }

    #if os(iOS)
    /// 1h's bottom action bar while `isSelecting`: 既読に・移動（アーカイブ）・
    /// 削除 — "まとめて翻訳" isn't rendered for the same reason
    /// `MessageListRow.trailingSwipeActions`'s doc comment gives for the
    /// swipe row's 翻訳/後で slots (no backing feature yet in this UI-
    /// restructuring pass). "移動" is simplified to "選択したスレッドをそれぞれの
    /// アカウントのアーカイブへ移動" rather than a full arbitrary-folder picker
    /// — see `docs/design-system.md`'s deviations section for why a full
    /// folder picker was judged out of this task's scope.
    private var selectionBottomBar: some View {
        HStack(spacing: OtegamiSpacing.xl) {
            selectionBarButton(title: "既読に", systemImage: "envelope.open", identifier: "markReadButton", action: markSelectedAsRead)
            selectionBarButton(title: "移動", systemImage: "archivebox", identifier: "archiveButton", action: archiveSelected)
            Spacer()
            selectionBarButton(title: "削除", systemImage: "trash", identifier: "deleteButton", action: deleteSelected, tint: OtegamiColor.destructive)
        }
        .padding(.horizontal, OtegamiSpacing.lg)
        .padding(.vertical, OtegamiSpacing.sm)
        .background(OtegamiColor.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(OtegamiColor.divider).frame(height: OtegamiStroke.secondary)
        }
        .disabled(selectedThreadIds.isEmpty)
    }

    private func selectionBarButton(title: String, systemImage: String, identifier: String, action: @escaping () -> Void, tint: Color = OtegamiColor.accent) -> some View {
        Button(action: action) {
            VStack(spacing: OtegamiSpacing.xs) {
                Image(systemName: systemImage)
                Text(title).font(OtegamiFont.caption())
            }
            .foregroundStyle(tint)
        }
        .otegamiMinimumTappable()
        .accessibilityIdentifier("messageList.selection.\(identifier)")
    }
    #endif

    /// Builds one row for the `ForEach` in `body` — pulled into its own
    /// `@ViewBuilder` method, with the row's interactive content
    /// (`Button`/swipe actions/context menu/long-press) in the standalone
    /// `MessageListRow` type, for the same reason `SidebarView`'s
    /// `mailboxRow(for:in:)`/`MailboxRow` split exists (see that pair's doc
    /// comments and docs/ci.md's troubleshooting notes): an `if let`
    /// binding plus a multi-argument view initializer plus several chained
    /// trailing-closure modifiers, all inline inside one `ForEach` row
    /// closure, is exactly the shape that hit `error: the compiler is
    /// unable to type-check this expression in reasonable time` on CI's
    /// toolchain for `SidebarView` — and this row (now with two
    /// `.swipeActions` groups, a long-press gesture, and a conditional
    /// context menu on top of what was already flagged as risky) is larger
    /// still.
    @ViewBuilder
    private func threadRow(for summary: ThreadSummary) -> some View {
        if let threadId = summary.thread.id {
            MessageListRow(
                summary: summary,
                threadId: threadId,
                accountDisplayName: accountDisplayNames[summary.thread.accountId],
                showsAccountAccent: showsAccountAccent,
                isSelecting: isSelecting,
                isSelected: selectedThreadIds.contains(threadId),
                onSelect: handleThreadSelected,
                onToggleSelection: toggleSelection,
                onEnterSelection: enterSelectionMode,
                onToggleRead: toggleRead,
                onArchive: archiveThread,
                onDelete: deleteThread,
                onAppear: loadMoreIfNeeded
            )
        }
    }

    /// `MessageListRow.onSelect`'s target — writes `selectedThreadId` and
    /// forwards to `onThreadSelected`, the same two steps the inline
    /// `Button` action this replaced used to do directly (see this type's
    /// own doc comment on why a re-tap of the same row needs both).
    private func handleThreadSelected(_ threadId: Int64) {
        selectedThreadId = threadId
        onThreadSelected(threadId)
    }

    // MARK: - Bulk selection (1h)

    private func enterSelectionMode(startingWith threadId: Int64) {
        guard !isSelecting else { return }
        isSelecting = true
        selectedThreadIds = [threadId]
        onSelectionModeChanged(true)
    }

    private func exitSelectionMode() {
        guard isSelecting else { return }
        isSelecting = false
        selectedThreadIds = []
        onSelectionModeChanged(false)
    }

    private func toggleSelection(_ threadId: Int64) {
        if selectedThreadIds.contains(threadId) {
            selectedThreadIds.remove(threadId)
        } else {
            selectedThreadIds.insert(threadId)
        }
    }

    private var isAllVisibleSelected: Bool {
        let visibleIds = Set(displayedSummaries.compactMap(\.thread.id))
        return !visibleIds.isEmpty && visibleIds.isSubset(of: selectedThreadIds)
    }

    private func toggleSelectAll() {
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

    private func markSelectedAsRead() {
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
    /// picker.
    private func archiveSelected() {
        let targets = selectedTargets()
        let ids = selectedThreadIds
        exitSelectionMode()
        scheduleUndo(threadIds: ids, message: "\(ids.count)件のスレッドをアーカイブしました") {
            for summary in targets { await commitArchive(summary) }
        }
    }

    private func deleteSelected() {
        let targets = selectedTargets()
        let ids = selectedThreadIds
        exitSelectionMode()
        scheduleUndo(threadIds: ids, message: "\(ids.count)件のスレッドを削除しました") {
            for summary in targets { await commitDelete(summary) }
        }
    }

    // MARK: - Undo (1g/1h)

    /// Optimistically hides `threadIds` from `displayedSummaries`
    /// (`pendingRemovalThreadIds`) and shows an `UndoToast` for
    /// `Self.undoWindow`; `commit` — the actual database mutation/opQueue
    /// enqueue — only runs once that window elapses without the user
    /// tapping "元に戻す" (`undoPending()`). Deliberately does *not* touch
    /// the database at all until then: unlike a "delete then restore on
    /// undo" design (which would need to reverse an opQueue entry that may
    /// already have replayed to the server), this can never race a real
    /// server commit — there's nothing to race until `commit` itself runs.
    /// Only one undo toast is shown at a time; scheduling a new one while
    /// an earlier one is still pending commits the earlier one immediately
    /// rather than silently dropping it (a second destructive action while
    /// the first's toast is still up shouldn't cancel the first's own
    /// eventual effect).
    private func scheduleUndo(threadIds: Set<Int64>, message: String, commit: @escaping () async -> Void) {
        pendingUndoTask?.cancel()
        if let previous = pendingUndo {
            Task { await previous.commit() }
        }
        pendingRemovalThreadIds.formUnion(threadIds)
        pendingUndo = PendingUndo(threadIds: threadIds, message: message, commit: commit)
        pendingUndoTask = Task {
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            await commit()
            pendingRemovalThreadIds.subtract(threadIds)
            pendingUndo = nil
        }
    }

    private func undoPending() {
        pendingUndoTask?.cancel()
        guard let pendingUndo else { return }
        pendingRemovalThreadIds.subtract(pendingUndo.threadIds)
        self.pendingUndo = nil
    }

    private var title: String {
        switch selection {
        case .unifiedInbox:
            "すべての受信トレイ"
        case .mailbox(let mailboxSelection):
            environment.accounts.first { $0.id == mailboxSelection.accountId }.map { $0.displayName } ?? "Inbox"
        }
    }

    private func observeThreads() async {
        switch selection {
        case .mailbox(let mailboxSelection):
            let observation = ThreadQuery.summariesObservation(mailboxId: mailboxSelection.mailboxId, limit: pageLimit)
            do {
                for try await fetched in observation.values(in: environment.database.dbWriter) {
                    summaries = fetched
                }
            } catch {
                // A failing observation just stops the list from updating
                // further; it doesn't clear what's already shown.
            }
        case .unifiedInbox:
            let accountIds = unifiedInboxAccountFilter.map { [$0] } ?? environment.accounts.map(\.id)
            let observation = ThreadQuery.unifiedInboxSummariesObservation(accountIds: accountIds, limit: pageLimit)
            do {
                for try await fetched in observation.values(in: environment.database.dbWriter) {
                    summaries = fetched
                }
            } catch {
                // Same as above.
            }
        }
    }

    /// M10 pagination: called from every row's `.onAppear` — cheap even
    /// though that fires often (a `!=` comparison against the last item's
    /// id most of the time), and simpler than threading a "last visible
    /// index" through `List`. Only grows `pageLimit` when `currentItem` is
    /// the *last* row currently loaded **and** the page came back full
    /// (`summaries.count == pageLimit`) — a short page means the query
    /// already returned everything there is, so growing the limit further
    /// would just re-run the same observation for no new rows.
    private func loadMoreIfNeeded(currentItem: ThreadSummary) {
        guard !isSearchActive else { return } // search results aren't paginated this way; see SearchQuery.defaultResultLimit
        guard currentItem.id == summaries.last?.id else { return }
        guard summaries.count == pageLimit else { return }
        pageLimit += Self.pageStep
    }

    // MARK: - Search (M7, macOS only)

    /// Debounces `searchText`/`searchScope` changes by 300ms (plan: "入力
    /// 300ms デバウンス") before actually querying — cancels whatever search
    /// was already in flight so a fast typist never races two queries
    /// against the same `searchResults` state. Clearing the field (`
    /// isSearchActive == false`) skips the debounce and the query
    /// entirely: there's nothing to search, and the normal list should
    /// reappear immediately rather than after a delay.
    private func scheduleSearch() {
        searchTask?.cancel()
        guard isSearchActive else {
            isSearching = false
            searchResults = []
            return
        }
        let query = searchText
        let scope = searchScope
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(query: query, scope: scope)
        }
    }

    private func performSearch(query: String, scope: SearchScopeOption) async {
        let storeScope: OtegamiStore.SearchScope
        switch (selection, scope) {
        case (.mailbox(let mailboxSelection), .currentMailbox):
            storeScope = .mailbox(mailboxId: mailboxSelection.mailboxId)
        default:
            storeScope = .allAccounts(accountIds: environment.accounts.map(\.id))
        }
        do {
            let results = try await environment.database.dbWriter.read { db in
                try SearchQuery.threadSummaries(query: query, scope: storeScope, db: db)
            }
            guard !Task.isCancelled else { return }
            searchResults = results
        } catch {
            guard !Task.isCancelled else { return }
            searchResults = []
        }
        isSearching = false
    }

    /// Pull-to-refresh / the toolbar refresh button: differential sync
    /// (M3), scoped (M4) to whichever mailbox is actually being viewed —
    /// a single mailbox for `.mailbox`, or every account's INBOX for the
    /// unified inbox (plan: "サイドバー選択時 + 手動更新"). Replays any
    /// queued offline operations first, since "the user explicitly asked
    /// to reconnect" is exactly the moment those should get a chance to
    /// flush too.
    private func refresh() async {
        isSyncing = true
        defer { isSyncing = false }

        switch selection {
        case .mailbox(let mailboxSelection):
            guard let account = environment.accounts.first(where: { $0.id == mailboxSelection.accountId }) else { return }
            do {
                let auth: MailAuth
                do {
                    auth = try await environment.auth(for: account)
                } catch TokenStoreError.reauthenticationRequired {
                    syncErrorMessage = "再認証が必要です。設定からアカウントを再認証してください。"
                    return
                } catch {
                    syncErrorMessage = "保存された資格情報が見つかりません。アカウントを再追加してください。"
                    return
                }
                let mailboxPath = try await environment.database.dbWriter.read { db in
                    try MailboxRecord.fetchOne(db, key: mailboxSelection.mailboxId)?.path
                }
                _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
                if let mailboxPath {
                    _ = try await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth, scope: .mailbox(path: mailboxPath))
                } else {
                    _ = try await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth)
                }
            } catch {
                syncErrorMessage = "\(error)"
            }
        case .unifiedInbox:
            let accountsToRefresh = unifiedInboxAccountFilter
                .flatMap { filterId in environment.accounts.first { $0.id == filterId } }
                .map { [$0] } ?? environment.accounts
            for account in accountsToRefresh {
                guard let auth = try? await environment.auth(for: account) else { continue }
                _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
                _ = try? await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth, scope: .inboxOnly)
            }
        }
    }

    // MARK: - Row actions (M4/1g: thread-wide, applied to every message)

    /// Toggles every message in the thread to the opposite of the thread's
    /// current unread state — the swipe row's own single-thread action.
    /// `applyReadState(_:markingRead:)` below is the shared implementation
    /// bulk "既読に" also uses (forcing `markingRead: true` regardless of
    /// each thread's current state, rather than toggling).
    private func toggleRead(_ summary: ThreadSummary) {
        let markingRead = summary.thread.unreadCount > 0
        Task {
            await applyReadState(summary, markingRead: markingRead)
        }
    }

    /// Enqueues an absolute `setFlags` op per affected message (plan: "全
    /// メッセージへ適用、opQueue 経由") and makes a best-effort replay attempt
    /// right away. Shared by the swipe row's `toggleRead(_:)` and bulk
    /// selection's "既読に" button.
    private func applyReadState(_ summary: ThreadSummary, markingRead: Bool) async {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        do {
            try await environment.database.dbWriter.write { db in
                let messages = try ThreadQuery.messages(threadId: threadId, db: db)
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
                    guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
                    try OpQueue.enqueueSetFlags(
                        accountId: accountId, mailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [UInt32(message.uid)], flags: message.flags, db: db
                    )
                }
                try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
            }
            await replayOpQueueSoon(accountId: accountId)
        } catch {
            // Best-effort: the row simply doesn't update if this fails.
        }
    }

    /// The swipe row's single-thread archive action — schedules an undo
    /// window (see `scheduleUndo`'s doc comment) before actually running
    /// `commitArchive(_:)`.
    private func archiveThread(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        scheduleUndo(threadIds: [threadId], message: "スレッドをアーカイブしました") {
            await commitArchive(summary)
        }
    }

    /// Moves every message in the thread to its account's Archive-role
    /// mailbox (`MailboxRoleRecord.archive`) — mirrors `commitDelete(_:)`'s
    /// shape exactly, just with `OpQueue.enqueueMove(destinationMailboxId:)`
    /// in place of `enqueueDelete` (which instead resolves the account's
    /// Trash mailbox at *replay* time, not enqueue time — delete's payload
    /// carries no destination at all). A move needs the destination
    /// resolved up front since `MoveOpPayload` requires one. Best-effort: if
    /// this account's Archive mailbox hasn't synced down locally yet (a
    /// freshly-added account, or a provider with no Archive folder), this
    /// silently does nothing rather than erroring — same fallback shape as
    /// every other opQueue-enqueuing path in this file.
    private func commitArchive(_ summary: ThreadSummary) async {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        do {
            try await environment.database.dbWriter.write { db in
                guard let archiveMailboxId = try MailboxRecord
                    .filter(Column("accountId") == accountId && Column("role") == MailboxRoleRecord.archive.rawValue)
                    .fetchOne(db)?.id
                else { return }
                let messages = try ThreadQuery.messages(threadId: threadId, db: db)
                for message in messages {
                    guard let messageId = message.id, let uid = UInt32(exactly: message.uid) else { continue }
                    guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
                    guard mailbox.id != archiveMailboxId else { continue }
                    try OpQueue.enqueueMove(
                        accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [uid], destinationMailboxId: archiveMailboxId, db: db
                    )
                    try FTSIndexer.delete(messageId: messageId, db: db)
                    try MessageRecord.deleteOne(db, key: messageId)
                }
                try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
            }
            if isSearchActive {
                searchResults.removeAll { $0.id == summary.id }
            }
            await replayOpQueueSoon(accountId: accountId)
        } catch {
            // Best-effort, matching every other opQueue-enqueuing path in
            // this file.
        }
    }

    /// The swipe row's single-thread delete action — schedules an undo
    /// window before actually running `commitDelete(_:)`.
    private func deleteThread(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        scheduleUndo(threadIds: [threadId], message: "スレッドを削除しました") {
            await commitDelete(summary)
        }
    }

    /// Removes every message in the thread from the local list immediately
    /// (optimistic — the mailbox's/unified inbox's `ValueObservation` picks
    /// up the deletion right away, and `ThreadAssigner.recomputeAggregates`
    /// deletes the now-empty `thread` row) and enqueues one `delete` op per
    /// message (opQueue resolves each message's own account's Trash
    /// mailbox and issues the actual `MOVE` at replay time).
    private func commitDelete(_ summary: ThreadSummary) async {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        do {
            try await environment.database.dbWriter.write { db in
                let messages = try ThreadQuery.messages(threadId: threadId, db: db)
                for message in messages {
                    guard let messageId = message.id, let uid = UInt32(exactly: message.uid) else { continue }
                    guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
                    try OpQueue.enqueueDelete(
                        accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [uid], db: db
                    )
                    // M7: `messageSearchIndex` isn't a real foreign-keyed
                    // table, so this deletion needs its own explicit
                    // index cleanup alongside the `message` row's.
                    try FTSIndexer.delete(messageId: messageId, db: db)
                    try MessageRecord.deleteOne(db, key: messageId)
                }
                try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
            }
            // `searchResults` is a one-shot array, not a live
            // `ValueObservation` like `summaries` — the normal list
            // picks up a deletion automatically, but a search-mode row
            // needs this explicit nudge or the just-deleted thread
            // would keep showing until the next debounced re-search.
            if isSearchActive {
                searchResults.removeAll { $0.id == summary.id }
            }
            await replayOpQueueSoon(accountId: accountId)
        } catch {
            // Best-effort: whatever's left stays if this fails; the
            // swipe can be retried.
        }
    }

    private func replayOpQueueSoon(accountId: String) async {
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
        guard let auth = try? await environment.auth(for: account) else { return }
        _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
    }
}
