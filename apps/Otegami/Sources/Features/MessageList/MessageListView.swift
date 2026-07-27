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
    /// G「削除・アーカイブ時の挙動」: reports the currently-displayed thread
    /// order (by `thread.id`, in on-screen order) every time `summaries`
    /// changes, so a parent that also owns `ThreadDetailView`'s
    /// `onThreadRemoved` (`MailScreenView` on iOS, `RootView` on macOS) can
    /// resolve `MessagePostActionSettingsStore.nextThreadId(after:in:action:)`
    /// against a reasonably fresh snapshot. Not called for `searchResults`
    /// (this view's own inline `.searchable`, macOS only) — search's own
    /// ordering isn't in scope for this setting (`ThreadDetailView
    /// .onThreadRemoved`'s doc comment).
    var onSummariesChanged: ([Int64]) -> Void = { _ in }

    /// Backstop for `scheduleUndo`'s delayed commit — see that method's doc
    /// comment on why a background/terminate transition has to flush any
    /// pending delete/archive immediately rather than letting the undo
    /// window's `Task.sleep` run its course. Read via `.onChange` in `body`
    /// (declaring `@Environment(\.scenePhase)` directly is enough; no
    /// binding needed since this view never itself drives scene phase).
    @Environment(\.scenePhase) private var scenePhase

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

    /// A destructive action (delete/archive, single-row swipe or bulk)
    /// whose local database write has **already happened** — see
    /// `commitDelete`/`commitArchive`'s doc comment for why this design
    /// commits immediately rather than delaying the write itself (a real
    /// data-loss bug the first version of this feature had). What
    /// `scheduleUndo` actually delays is the *network* replay attempt;
    /// `undo` reverses the local write and cancels the not-yet-replayed
    /// opQueue rows if the user taps "元に戻す" before that.
    private struct PendingUndo {
        var threadIds: Set<Int64>
        var message: String
        var accountIds: Set<String>
        var undo: () async -> Void
    }
    @State private var pendingUndo: PendingUndo?
    @State private var pendingUndoTask: Task<Void, Never>?
    /// How long an undo toast stays up before its queued opQueue rows are
    /// allowed to actually replay to the server. 5s matches the common
    /// "Gmail-style" undo window long enough to react to, short enough not
    /// to leave a destructive action feeling unfinished.
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
        var isFlatMode: Bool
    }

    // MARK: - フラット表示 (B3)

    /// The inverse of the 「スレッド表示」 setting — when threading is *off*,
    /// `observeThreads()` queries
    /// `ThreadQuery.flatSummaries`/`unifiedInboxFlatSummaries` (one row per
    /// message) instead of `summariesObservation`/
    /// `unifiedInboxSummariesObservation` (one row per thread), but still
    /// populates the very same `summaries: [ThreadSummary]` this view
    /// already renders through `MessageListRow`/`ThreadRowView` — see
    /// `ThreadSummary.init(flatMessage:accountId:)`'s doc comment for how a
    /// single message masquerades as a "thread of one" with zero changes to
    /// either row view.
    ///
    /// Deliberate scope limit: this only affects the *normal* list — a
    /// `.searchable` search (macOS's inline mailbox search, and iOS's
    /// separate `SearchTabView`) keeps showing thread-grouped results
    /// regardless of this setting. `SearchQuery.threadSummaries` has no
    /// message-level equivalent, and search results are a comparatively
    /// small, transient list where "grouped vs. flat" matters far less than
    /// it does for a whole mailbox's worth of everyday scrolling — building
    /// a second flat search query was judged not worth the added surface
    /// area for this pass.
    ///
    /// Also deliberate: every row action (既読/未読・アーカイブ・迷惑メール・
    /// ピン留め・削除) still operates on the row's *whole* underlying thread
    /// even in flat mode, not just the one message the row displays — see
    /// `ThreadSummary.init(flatMessage:accountId:)`'s doc comment. Acting on
    /// any message in a conversation moving/removing the whole conversation
    /// is normal mail-client behavior (and exactly what grouped mode
    /// already does), and building a fully separate per-message action path
    /// alongside the existing thread-scoped one would have doubled this
    /// view's already-large action surface for comparatively little
    /// day-to-day benefit — flat mode's core promise ("一覧がメール単位になる")
    /// is about *what's shown*, not a new per-message operation model.
    @AppStorage(ListDisplaySettingsStore.threadingKey) private var isThreadingEnabled = ListDisplaySettingsStore.defaultThreading

    /// Flat mode is simply "threading turned off" — kept as a derived value
    /// so the rest of this view (and `ObservationKey`) can keep reading in
    /// the affirmative "is this the flat query?" direction.
    private var isFlatMode: Bool { !isThreadingEnabled }

    /// Whitespace-only input (including the empty string right after
    /// `.searchable` clears) is "not searching" — the normal `summaries`
    /// list shows, exactly like before M7.
    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the `List` actually renders: search results while a query is
    /// active (macOS only — iOS never populates `searchText`, this view no
    /// longer hosts a search field there), the live `ThreadQuery`
    /// observation otherwise. No separate "pending removal" filter needed —
    /// `commitDelete`/`commitArchive` write to the database immediately, so
    /// a deleted/archived thread is already gone from `summaries` via the
    /// live observation by the time this is read (see those methods' doc
    /// comment for why the undo window no longer delays the local write
    /// itself). Rows, `MessageListRow`, and every swipe/bulk action are
    /// shared between the search-results and normal-list cases — marking a
    /// search hit read or deleting it works exactly like it does from the
    /// normal list.
    private var displayedSummaries: [ThreadSummary] {
        isSearchActive ? searchResults : summaries
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
    ///
    /// design-phase-3: also requires more than one account to exist at all.
    /// With exactly one account, "全部"/unified inbox and that account's own
    /// mailbox show the identical set of messages, so a rail/label naming
    /// the only account that could possibly appear is pure noise — and,
    /// worse, it eats into the subject's available width on every single
    /// row for a piece of information that's always the same value. Caught
    /// by actually looking at a single-account screenshot (`docs/design-
    /// system.md`'s design-phase-3 section) rather than in the handoff,
    /// which didn't consider the one-account case explicitly.
    private var showsAccountAccent: Bool {
        guard case .unifiedInbox = selection else { return false }
        guard unifiedInboxAccountFilter == nil else { return false }
        return environment.accounts.count > 1
    }

    private var accountDisplayNames: [String: String] {
        Dictionary(uniqueKeysWithValues: environment.accounts.map { ($0.id, $0.displayName) })
    }

    /// D「アカウントのラベル色を変更可能に」— only non-`nil` `labelColorKey`s are
    /// included; `ThreadRowView`/`AccountColorRail`/`SenderAvatar` already
    /// treat a missing dictionary entry the same as an explicit `nil`
    /// (auto-assignment).
    private var accountLabelColorKeys: [String: String] {
        Dictionary(uniqueKeysWithValues: environment.accounts.compactMap { account in
            account.labelColorKey.map { (account.id, $0) }
        })
    }

    // MARK: - Empty state (実機バグ調査: 「アーカイブ運用で INBOX が本当に空」を
    // 「同期が失敗している」と誤読させないための分岐, docs/verify.md)

    /// `AccountRecord.lastSyncError` for whichever account(s) this view's
    /// `selection` could plausibly be empty *because of* a failed sync —
    /// `nil` means "as far as we know, the relevant account(s) last synced
    /// cleanly", which is also true before the first sync ever runs (that's
    /// fine: the empty state then falls back to the same "同期中…" as any
    /// other pre-sync moment via `isSyncing`, not a spurious error message).
    /// `.unifiedInbox` with no `unifiedInboxAccountFilter` (1a's "全部" chip)
    /// has no single account to check, so it reports an error if *any*
    /// account last failed — an empty unified inbox while even one account
    /// is in a known-bad state is exactly the ambiguous case this exists to
    /// resolve in favor of "re-sync", not silently "no mail".
    private var currentAccountLastSyncError: String? {
        switch selection {
        case .mailbox(let mailboxSelection):
            return environment.accounts.first { $0.id == mailboxSelection.accountId }?.lastSyncError
        case .unifiedInbox:
            let accountId = unifiedInboxAccountFilter
            if let accountId {
                return environment.accounts.first { $0.id == accountId }?.lastSyncError
            }
            return environment.accounts.compactMap(\.lastSyncError).first
        }
    }

    /// "メッセージがありません" (something might be missing — check again) only
    /// once there's a reason to doubt the sync, i.e. mid-sync or after a
    /// recorded failure; a *known-clean* empty mailbox (the common case for
    /// an inbox-zero workflow — this is the exact real-device report that
    /// prompted this split, see docs/verify.md) instead says "メールはあり
    /// ません", which doesn't imply anything went wrong.
    private var emptyStateTitle: LocalizedStringKey {
        (isSyncing || currentAccountLastSyncError != nil) ? "メッセージがありません" : "メールはありません"
    }

    /// No description at all for the known-clean empty case — "メールはあり
    /// ません" alone doesn't need a "here's what to do about it" line the
    /// way the syncing/error cases do.
    private var emptyStateDescription: Text? {
        if isSyncing { return Text("同期中…") }
        if currentAccountLastSyncError != nil { return Text("再同期を試してください。") }
        return nil
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
        // design-phase-3: a `List` with no explicit `Section`s still gets
        // treated as one implicit section, and iOS 17+'s default
        // inter-section spacing (`ListSectionSpacing.default`, a fixed
        // ~20-30pt-plus gap meant to separate *visually distinct* grouped
        // sections) applies above it regardless — with nothing else above
        // the list on macOS/most iOS screens this is invisible (it just
        // reads as ordinary top padding), but on iOS's 1a mail tab, where
        // `AccountFilterChipRow` sits directly above this `List` in the
        // same `VStack`, it showed up as a conspicuous unstyled empty band
        // between the chips and the first row (caught by actually looking
        // at a screenshot, not by reading the modifier list — see
        // `docs/design-system.md`'s design-phase-3 section). `.compact`
        // collapses it to the same tight spacing this app's own row
        // dividers already use. iOS-only: `.listSectionSpacing` isn't
        // available on macOS in this SDK at all (this app's
        // `NavigationSplitView` 3-pane layout has nothing above this list
        // in the same `VStack` in the first place — `CLAUDE.md`'s "macOS
        // は現状の `NavigationSplitView` 3ペインを維持する" — so there was
        // never a gap to fix there).
        #if os(iOS)
        .listSectionSpacing(.compact)
        #endif
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
                    emptyStateTitle,
                    systemImage: "envelope",
                    description: emptyStateDescription
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
        .onChange(of: summaries) { _, newValue in
            onSummariesChanged(newValue.compactMap(\.thread.id))
        }
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
        .task(id: ObservationKey(selection: selection, accountFilter: unifiedInboxAccountFilter, accountIds: environment.accounts.map(\.id), pageLimit: pageLimit, isFlatMode: isFlatMode)) {
            await observeThreads()
        }
        // Not required for correctness anymore (the local write already
        // happened by the time a `PendingUndo` exists — see `commitDelete`/
        // `commitArchive`'s doc comment), but backgrounding is also the
        // natural point to give up on "undo" and let the already-queued
        // opQueue rows replay right away instead of waiting out the rest of
        // the window for no one to see.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active, let pendingUndo else { return }
            pendingUndoTask?.cancel()
            self.pendingUndo = nil
            Task { await replayOpQueueSoon(accountIds: pendingUndo.accountIds) }
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

    // 表示・操作改善バッチ「表示言語の設定」: `title: String`のままだと
    // `Text(title)`がverbatim (非ローカライズ) 呼び出しになる —
    // `LocalizedStringKey`に変えるだけで、呼び出し側の文字列リテラルは
    // そのまま`Localizable.xcstrings`のキーとして解決されるようになる。
    private func selectionBarButton(title: LocalizedStringKey, systemImage: String, identifier: String, action: @escaping () -> Void, tint: Color = OtegamiColor.accent) -> some View {
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
                accountLabelColorKey: accountLabelColorKeys[summary.thread.accountId],
                showsAccountAccent: showsAccountAccent,
                isSelecting: isSelecting,
                isSelected: selectedThreadIds.contains(threadId),
                onSelect: handleThreadSelected,
                onToggleSelection: toggleSelection,
                onEnterSelection: enterSelectionMode,
                onToggleRead: toggleRead,
                onArchive: archiveThread,
                onDelete: deleteThread,
                onJunk: junkThread,
                onPin: togglePin,
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
    /// picker. Each target thread's messages are moved (deleted locally,
    /// `move` op enqueued) immediately, same as the swipe row's own
    /// `archiveThread(_:)` — see `commitArchive`'s doc comment for why this
    /// commits right away rather than waiting out the undo window first.
    private func archiveSelected() {
        let targets = selectedTargets()
        let ids = selectedThreadIds
        let accountIds = Set(targets.map(\.thread.accountId))
        exitSelectionMode()
        Task {
            var snapshots: [RemovedMessagesSnapshot] = []
            for summary in targets {
                if let snapshot = await commitArchive(summary) { snapshots.append(snapshot) }
            }
            guard !snapshots.isEmpty else { return }
            scheduleUndo(threadIds: ids, message: "\(ids.count)件のスレッドをアーカイブしました", accountIds: accountIds) {
                for snapshot in snapshots { await undoRemoval(snapshot) }
            }
        }
    }

    private func deleteSelected() {
        let targets = selectedTargets()
        let ids = selectedThreadIds
        let accountIds = Set(targets.map(\.thread.accountId))
        exitSelectionMode()
        Task {
            var snapshots: [RemovedMessagesSnapshot] = []
            for summary in targets {
                if let snapshot = await commitDelete(summary) { snapshots.append(snapshot) }
            }
            guard !snapshots.isEmpty else { return }
            scheduleUndo(threadIds: ids, message: "\(ids.count)件のスレッドを削除しました", accountIds: accountIds) {
                for snapshot in snapshots { await undoRemoval(snapshot) }
            }
        }
    }

    // MARK: - Undo (1g/1h)

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
    private func scheduleUndo(threadIds: Set<Int64>, message: String, accountIds: Set<String>, undo: @escaping () async -> Void) {
        pendingUndoTask?.cancel()
        if let previous = pendingUndo {
            Task { await replayOpQueueSoon(accountIds: previous.accountIds) }
        }
        pendingUndo = PendingUndo(threadIds: threadIds, message: message, accountIds: accountIds, undo: undo)
        pendingUndoTask = Task {
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            pendingUndo = nil
            await replayOpQueueSoon(accountIds: accountIds)
        }
    }

    private func undoPending() {
        pendingUndoTask?.cancel()
        guard let pendingUndo else { return }
        let undo = pendingUndo.undo
        self.pendingUndo = nil
        Task { await undo() }
    }

    private var title: String {
        switch selection {
        case .unifiedInbox:
            // 表示・操作改善バッチ「表示言語の設定」: `Text(title)`は
            // `Text(String)`(verbatim)なので、リテラルを直接書くだけでは
            // ローカライズされない — `String(localized:)`で明示的に
            // `Localizable.xcstrings`を引く。
            String(localized: "すべての受信トレイ")
        case .mailbox(let mailboxSelection):
            environment.accounts.first { $0.id == mailboxSelection.accountId }.map { $0.displayName } ?? "Inbox"
        }
    }

    private func observeThreads() async {
        switch selection {
        case .mailbox(let mailboxSelection):
            let observation: ValueObservation<ValueReducers.Fetch<[ThreadSummary]>> = isFlatMode
                ? ThreadQuery.flatSummariesObservation(mailboxId: mailboxSelection.mailboxId, limit: pageLimit, accountId: mailboxSelection.accountId)
                : ThreadQuery.summariesObservation(mailboxId: mailboxSelection.mailboxId, limit: pageLimit)
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
            let observation: ValueObservation<ValueReducers.Fetch<[ThreadSummary]>> = isFlatMode
                ? ThreadQuery.unifiedInboxFlatSummariesObservation(accountIds: accountIds, limit: pageLimit)
                : ThreadQuery.unifiedInboxSummariesObservation(accountIds: accountIds, limit: pageLimit)
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
            // One account failing must not stop the others from refreshing,
            // but the failures must not vanish either — an earlier version
            // `try?`'d everything here, which meant a unified-inbox refresh
            // could fail for *every* account (e.g. a real Gmail/iCloud
            // account whose sync path is broken) with no visible symptom
            // beyond the empty-state's "再同期を試してください". Collect
            // per-account failures and surface them through the same alert
            // the single-mailbox path already uses.
            var failures: [String] = []
            for account in accountsToRefresh {
                do {
                    let auth = try await environment.auth(for: account)
                    _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
                    _ = try await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth, scope: .inboxOnly)
                } catch {
                    failures.append("\(account.email): \(error)")
                }
            }
            if !failures.isEmpty {
                syncErrorMessage = failures.joined(separator: "\n")
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

    // MARK: - Pinning (E9)

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
    private func togglePin(_ summary: ThreadSummary) {
        let pinning = !summary.thread.isPinned
        Task { await applyPinState(summary, pinning: pinning) }
    }

    /// No undo toast (unlike delete/archive) — pinning never removes a row
    /// from the list, it only reorders it, so the action is already
    /// trivially reversible with one more tap on the same button.
    private func applyPinState(_ summary: ThreadSummary, pinning: Bool) async {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        let syncEnabled = PinSettingsStore.isSyncWithFlaggedEnabled
        do {
            try await environment.database.dbWriter.write { db in
                let messages = try ThreadQuery.messages(threadId: threadId, db: db)
                for var message in messages {
                    guard message.isPinnedLocal != pinning else { continue }
                    message.isPinnedLocal = pinning
                    if syncEnabled {
                        if pinning {
                            message.flags.insert(.flagged)
                        } else {
                            message.flags.remove(.flagged)
                        }
                    }
                    message.updatedAt = Date()
                    try message.update(db)
                    guard syncEnabled, let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
                    try OpQueue.enqueueSetFlags(
                        accountId: accountId, mailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [UInt32(message.uid)], flags: message.flags, db: db
                    )
                }
                try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
            }
            if syncEnabled { await replayOpQueueSoon(accountId: accountId) }
        } catch {
            // Best-effort, matching every other opQueue-enqueuing path in
            // this file.
        }
    }

    // MARK: - Junk (D8)

    /// D8「迷惑メールにする」— mirrors `archiveThread(_:)`/`commitArchive(_:)`'s
    /// shape exactly, just moving to the account's Junk-role mailbox at
    /// *replay* time (`OpQueue.enqueueJunk`, resolved/self-healed by
    /// `OpQueueProcessor.resolveOrCreateJunkMailbox` the same way `delete`
    /// resolves Trash) rather than a pre-resolved local Archive mailbox id.
    private func junkThread(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        Task {
            guard let snapshot = await commitJunk(summary) else { return }
            scheduleUndo(threadIds: [threadId], message: "スレッドを迷惑メールにしました", accountIds: [accountId]) {
                await undoRemoval(snapshot)
            }
        }
    }

    /// Removes every message in the thread from the local list immediately
    /// and enqueues one `junk` op per message — same "commit immediately,
    /// make undo fully reversible" shape as `commitDelete(_:)`/
    /// `commitArchive(_:)` (see either's doc comment for why).
    private func commitJunk(_ summary: ThreadSummary) async -> RemovedMessagesSnapshot? {
        guard let threadId = summary.thread.id else { return nil }
        let accountId = summary.thread.accountId
        do {
            let snapshot = try await environment.database.dbWriter.write { db -> RemovedMessagesSnapshot? in
                guard let thread = try ThreadRecord.fetchOne(db, key: threadId) else { return nil }
                let messages = try ThreadQuery.messages(threadId: threadId, db: db)
                let beforeMaxOpId = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM opQueue") ?? 0
                for message in messages {
                    guard let messageId = message.id, let uid = UInt32(exactly: message.uid) else { continue }
                    guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
                    try OpQueue.enqueueJunk(
                        accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [uid], db: db
                    )
                    try FTSIndexer.delete(messageId: messageId, db: db)
                    try MessageRecord.deleteOne(db, key: messageId)
                }
                try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
                let opQueueIds = try Int64.fetchAll(db, sql: "SELECT id FROM opQueue WHERE id > ? ORDER BY id", arguments: [beforeMaxOpId])
                return RemovedMessagesSnapshot(thread: thread, messages: messages, opQueueIds: opQueueIds)
            }
            guard let snapshot else { return nil }
            if isSearchActive {
                searchResults.removeAll { $0.id == summary.id }
            }
            return snapshot
        } catch {
            return nil
        }
    }

    /// The swipe row's single-thread archive action — schedules an undo
    /// window (see `scheduleUndo`'s doc comment) before actually running
    /// `commitArchive(_:)`.
    /// The swipe row's single-thread archive action — commits immediately
    /// (see `commitArchive`'s doc comment), then hands the resulting
    /// snapshot to `scheduleUndo`.
    private func archiveThread(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        Task {
            guard let snapshot = await commitArchive(summary) else { return }
            scheduleUndo(threadIds: [threadId], message: "スレッドをアーカイブしました", accountIds: [accountId]) {
                await undoRemoval(snapshot)
            }
        }
    }

    /// Removes every message in the thread from its current mailbox and
    /// enqueues one `archive` op per message — mirrors `commitDelete(_:)`'s
    /// shape exactly, just with `OpQueue.enqueueArchive` in place of
    /// `enqueueDelete`. Like `.delete`, `.archive`'s destination (or, for a
    /// Gmail account, "no destination — just unlabel the source") is
    /// resolved by `OpQueueProcessor` at *replay* time, not here at enqueue
    /// time — see `OpQueueKind.archive`'s doc comment for why a
    /// pre-resolved local Archive-role mailbox lookup used to make
    /// archiving silently do nothing on a real Gmail account (Gmail has no
    /// `\Archive` folder at all).
    ///
    /// Commits the local database write (and enqueues the `move` op)
    /// *immediately*, unlike this feature's first version — see
    /// `RemovedMessagesSnapshot`/`undoRemoval(_:)`'s doc comment for why:
    /// delaying the local write itself (so "undo" could just... not commit
    /// it) turned out to have a real data-loss bug, caught by
    /// `scripts/verify-ios-m3.sh`'s offline swipe-delete phase — an app
    /// relaunch inside the old delayed-commit window silently lost the
    /// action entirely, since the pending `Task.sleep` driving the eventual
    /// write died with the process before ever running. Committing
    /// immediately (durable to disk before this method even returns) and
    /// instead making *undo itself* fully reversible closes that gap: the
    /// opQueue row this enqueues survives any kill regardless of timing,
    /// and a normal relaunch's existing foreground-sync replay picks it up
    /// exactly like any other queued op.
    private func commitArchive(_ summary: ThreadSummary) async -> RemovedMessagesSnapshot? {
        guard let threadId = summary.thread.id else { return nil }
        let accountId = summary.thread.accountId
        do {
            let snapshot = try await environment.database.dbWriter.write { db -> RemovedMessagesSnapshot? in
                guard let thread = try ThreadRecord.fetchOne(db, key: threadId) else { return nil }
                let messages = try ThreadQuery.messages(threadId: threadId, db: db)
                let beforeMaxOpId = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM opQueue") ?? 0
                for message in messages {
                    guard let messageId = message.id, let uid = UInt32(exactly: message.uid) else { continue }
                    guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
                    guard mailbox.role != .archive else { continue }
                    try OpQueue.enqueueArchive(
                        accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [uid], db: db
                    )
                    try FTSIndexer.delete(messageId: messageId, db: db)
                    try MessageRecord.deleteOne(db, key: messageId)
                }
                try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
                let opQueueIds = try Int64.fetchAll(db, sql: "SELECT id FROM opQueue WHERE id > ? ORDER BY id", arguments: [beforeMaxOpId])
                return RemovedMessagesSnapshot(thread: thread, messages: messages, opQueueIds: opQueueIds)
            }
            guard let snapshot else { return nil }
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
    /// (see `commitDelete`'s doc comment), then hands the resulting
    /// snapshot to `scheduleUndo`.
    private func deleteThread(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        Task {
            guard let snapshot = await commitDelete(summary) else { return }
            scheduleUndo(threadIds: [threadId], message: "スレッドを削除しました", accountIds: [accountId]) {
                await undoRemoval(snapshot)
            }
        }
    }

    /// Removes every message in the thread from the local list immediately
    /// (optimistic — the mailbox's/unified inbox's `ValueObservation` picks
    /// up the deletion right away, and `ThreadAssigner.recomputeAggregates`
    /// deletes the now-empty `thread` row) and enqueues one `delete` op per
    /// message (opQueue resolves each message's own account's Trash
    /// mailbox and issues the actual `MOVE` at replay time) — immediately,
    /// same as `commitArchive(_:)`; see its doc comment for why "immediately,
    /// with a fully-reversible undo" replaced this feature's first
    /// "delay the whole write" design.
    private func commitDelete(_ summary: ThreadSummary) async -> RemovedMessagesSnapshot? {
        guard let threadId = summary.thread.id else { return nil }
        let accountId = summary.thread.accountId
        do {
            let snapshot = try await environment.database.dbWriter.write { db -> RemovedMessagesSnapshot? in
                guard let thread = try ThreadRecord.fetchOne(db, key: threadId) else { return nil }
                let messages = try ThreadQuery.messages(threadId: threadId, db: db)
                let beforeMaxOpId = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM opQueue") ?? 0
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
                let opQueueIds = try Int64.fetchAll(db, sql: "SELECT id FROM opQueue WHERE id > ? ORDER BY id", arguments: [beforeMaxOpId])
                return RemovedMessagesSnapshot(thread: thread, messages: messages, opQueueIds: opQueueIds)
            }
            guard let snapshot else { return nil }
            // `searchResults` is a one-shot array, not a live
            // `ValueObservation` like `summaries` — the normal list
            // picks up a deletion automatically, but a search-mode row
            // needs this explicit nudge or the just-deleted thread
            // would keep showing until the next debounced re-search.
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

    /// Everything `undoRemoval(_:)` needs to reverse one `commitDelete`/
    /// `commitArchive` call: the thread's aggregate row and every message
    /// row it removed (captured *before* removal, full field data —
    /// re-inserting them restores the exact same `id`s, so nothing else in
    /// the app needs to know a delete/archive was ever reversed), plus the
    /// opQueue row ids that call enqueued (captured via a before/after
    /// max-`id` diff within the same transaction — `OpQueue.enqueueDelete`/
    /// `enqueueMove` don't themselves return the id they just inserted).
    private struct RemovedMessagesSnapshot {
        var thread: ThreadRecord
        var messages: [MessageRecord]
        var opQueueIds: [Int64]
    }

    /// Reverses one `commitDelete`/`commitArchive` call: deletes the
    /// opQueue rows it enqueued (a no-op for any that already replayed —
    /// see `scheduleUndo`'s doc comment on that race) and re-inserts every
    /// removed message plus the thread aggregate row, each with its
    /// original `id` (GRDB's default `insert` includes an already-set
    /// primary key value in the `INSERT` statement, and the row it
    /// occupied was just deleted, so there's no conflict to resolve).
    /// `FTSIndexer.reindex` restores each message's search-index row the
    /// same way `FTSIndexer.delete` removed it. Best-effort, matching every
    /// other opQueue-enqueuing/db-mutating path in this file — a failure
    /// here just leaves the delete/archive applied, same as if "元に戻す"
    /// had never been tapped.
    private func undoRemoval(_ snapshot: RemovedMessagesSnapshot) async {
        do {
            try await environment.database.dbWriter.write { db in
                try OpQueueRecord.deleteAll(db, keys: snapshot.opQueueIds)
                for message in snapshot.messages {
                    var restored = message
                    try restored.insert(db)
                    if let messageId = restored.id {
                        try FTSIndexer.reindex(messageId: messageId, db: db)
                    }
                }
                guard let threadId = snapshot.thread.id else { return }
                if try ThreadRecord.fetchOne(db, key: threadId) == nil {
                    var restoredThread = snapshot.thread
                    try restoredThread.insert(db)
                } else {
                    try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
                }
            }
        } catch {
            // Best-effort — see doc comment above.
        }
    }

    private func replayOpQueueSoon(accountIds: Set<String>) async {
        for accountId in accountIds {
            await replayOpQueueSoon(accountId: accountId)
        }
    }

    private func replayOpQueueSoon(accountId: String) async {
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
        guard let auth = try? await environment.auth(for: account) else { return }
        _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
    }
}
