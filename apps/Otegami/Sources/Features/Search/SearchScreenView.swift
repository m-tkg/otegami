import SwiftUI
import OtegamiStore
import SyncEngine

/// iOS's 検索画面 (新画面構成 (2)): presented as a sheet from
/// `MailScreenView`'s header search button, or from `ThreadDetailView`'s
/// footer toolbar「検索」button (opened with `presetQuery` already filled in
/// as `from:<差出人>` — "そのメールの from で絞り込まれた状態で開く"). Replaces
/// design-phase-2's dedicated 検索タブ now that the bottom tab bar is gone
/// (`docs/design-system.md`'s design-phase-2 record of the original M7→1a
/// move is superseded by this one).
///
/// Adds, on top of the design-phase-2/M7 baseline this evolved from:
/// - **アカウントの絞り込み** (`SearchAccountFilterChipRow`, only shown with
///   2+ accounts — same "redundant with only one" gate `showsAccountAccent`
///   already uses elsewhere).
/// - **検索演算子** (`from:`/`to:`/`cc:`/`subject:` — `SearchQuery.parse`
///   does the actual interpretation; this view just types raw text through
///   unchanged and lets that layer sort out operators vs. free text). The
///   prompt/hint text below the search field is this operator syntax's
///   discovery affordance (指示: "演算子の存在をユーザーが発見できるUI").
/// - **検索履歴** (`SearchHistoryQuery`/`historyList`): the most recent
///   queries, tap to re-run, swipe or "すべて削除" to remove. Shown only
///   before a query becomes active (`isActive == false`) — once there's a
///   real query, the results (or empty state) take over the same space.
///
/// Reuses `ThreadRowView` (the same 1d row `MessageListView`/
/// `MessageListRow` render) so a search hit looks identical to the same
/// thread in the mail list.
///
/// Deliberately simpler than `MessageListView`: no swipe actions, no bulk
/// selection, no pagination beyond `SearchQuery`'s own built-in result cap
/// (`SearchQuery.defaultResultLimit`) — a search results screen's job is
/// "find the thread, open it," not full list-management chrome.
struct SearchScreenView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    var onReply: (Int64, Bool, Bool) -> Void
    /// Set by a caller that already knows what to search for (メール本文
    /// 画面の「検索」ツールバーボタン) — applied once, on appear, then this
    /// view's own `searchText` state takes over.
    var presetQuery: String?

    @State private var searchText = ""
    @State private var results: [ThreadSummary] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedThreadId: Int64?
    /// 実機バグ報告「スレッド表示をオフにしてるのに、スレッドで表示される
    /// ことがある」対策 — `MessageListView.selectedMessageId`と同じ役割:
    /// `isThreadingEnabled`がオフの間、`performSearch`はグループ化された
    /// スレッドではなく`ThreadQuery`のフラット行と同じ「1メッセージ1行」の
    /// 結果を返すようになった (`SearchQuery.flatMessageSummaries`) —
    /// そのタップされた行自身の`singleMessageId`をここに保持し、
    /// `ThreadEntryView.preselectedMessageId`へそのまま渡す。
    @State private var selectedMessageId: Int64?
    /// 一覧画面 (`MessageListView`) と同じ`UserDefaults`キーを共有する —
    /// 「スレッド表示」設定は画面をまたいで一貫していなければならない
    /// (この画面はそれ専用の設定 UI を持たない、一覧側の設定がそのまま
    /// 効く)。
    @AppStorage(ListDisplaySettingsStore.threadingKey) private var isThreadingEnabled = ListDisplaySettingsStore.defaultThreading
    /// design-phase-3 (1j)'s filter chip row — see `SearchFilterOption`'s
    /// doc comment on why this filters `results` client-side rather than
    /// re-querying.
    @State private var filter: SearchFilterOption = .all
    /// 新画面構成 (2): `nil` = 全アカウント横断。
    @State private var accountFilter: String?
    @State private var historyEntries: [SearchHistoryRecord] = []

    private var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var accountDisplayNames: [String: String] {
        Dictionary(uniqueKeysWithValues: environment.accounts.map { ($0.id, $0.displayName) })
    }

    /// D「アカウントのラベル色を変更可能に」— see `MessageListView`'s identical
    /// property doc comment.
    private var accountLabelColorKeys: [String: String] {
        Dictionary(uniqueKeysWithValues: environment.accounts.compactMap { account in
            account.labelColorKey.map { (account.id, $0) }
        })
    }

    private var filteredResults: [ThreadSummary] {
        filter == .all ? results : results.filter(filter.matches)
    }

    /// 1j: "結果は「人」「メール」でセクション分け" — a result is bucketed under
    /// "人" when the query text itself matches the latest message's sender
    /// (name or address), "メール" otherwise. See `docs/design-system.md`'s
    /// design-phase-3 section for the full approximation this makes.
    private var peopleResults: [ThreadSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        return filteredResults.filter { isSenderMatch($0, query: query) }
    }

    private var mailResults: [ThreadSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return filteredResults }
        return filteredResults.filter { !isSenderMatch($0, query: query) }
    }

    private func isSenderMatch(_ summary: ThreadSummary, query: String) -> Bool {
        guard let from = summary.latestMessage?.fromAddresses.first else { return false }
        if let name = from.name, !name.isEmpty, name.lowercased().contains(query) { return true }
        return from.address.lowercased().contains(query)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if environment.accounts.count > 1 {
                    SearchAccountFilterChipRow(accounts: environment.accounts, selectedAccountId: $accountFilter)
                }
                if isActive {
                    SearchFilterChipRow(selection: $filter)
                }
                resultsList
            }
            .background(OtegamiColor.background)
            .navigationTitle("検索")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                        .accessibilityIdentifier("search.closeButton")
                }
            }
            .searchable(text: $searchText, prompt: "差出人・件名・本文 (from:/to:/subject: も使えます)")
            .onChange(of: searchText) { _, _ in scheduleSearch() }
            .onChange(of: accountFilter) { _, _ in scheduleSearch() }
            // 実機バグ報告「スレッド表示をオフにしてるのに、スレッドで表示
            // されることがある」対策の一環 — 検索結果自体も`isFlatMode`を
            // 反映するようになった (`performSearch`) ため、設定を切り替えた
            // ままの古いグルーピング結果が検索中の画面に残らないよう
            // 再検索する。
            .onChange(of: isThreadingEnabled) { _, _ in scheduleSearch() }
            .navigationDestination(item: $selectedThreadId) { threadId in
                // `preselectedMessageId`: 通常のグループ化された結果
                // (`summary.singleMessageId == nil`) では`nil`のまま
                // (`ThreadEntryView`がメッセージ数を数えて選択画面を出すか
                // 判断する) — スレッド表示オフ中の結果はフラット (1メッセージ
                // 1行) なので、`MessageListView`のフラット行と同じく
                // `singleMessageId`を必ず伝える (`searchRow(for:)`参照)。
                ThreadEntryView(threadId: threadId, preselectedMessageId: selectedMessageId, onReply: onReply)
            }
        }
        .tint(OtegamiColor.accent)
        .task { await loadHistory() }
        .onAppear {
            guard let presetQuery, searchText != presetQuery else { return }
            searchText = presetQuery
        }
    }

    /// Split out of `body` (`docs/ci.md`'s type-check-timeout discipline —
    /// two `Section`s each with their own `ForEach`, inline in the same
    /// expression as the filter chip rows and `.searchable`'s modifier
    /// chain, is exactly the shape that's bitten this app before).
    private var resultsList: some View {
        List {
            if !peopleResults.isEmpty {
                Section("人") {
                    ForEach(peopleResults) { summary in
                        searchRow(for: summary)
                    }
                }
            }
            if !mailResults.isEmpty {
                Section(peopleResults.isEmpty ? "" : "メール") {
                    ForEach(mailResults) { summary in
                        searchRow(for: summary)
                    }
                }
            }
        }
        .accessibilityIdentifier("search.list")
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .overlay { overlayContent }
    }

    /// Kept as an `.overlay` on top of (not a row *inside*) `search.list` —
    /// matching M7's original design — so `search.list.cells.count` stays a
    /// reliable "how many real result rows" signal for both the loading
    /// state and the zero-results state, not just the search history list.
    @ViewBuilder
    private var overlayContent: some View {
        if !isActive {
            historyOrPromptState
        } else if isSearching {
            ProgressView("検索中…")
                .accessibilityIdentifier("search.loading")
        } else if filteredResults.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .accessibilityIdentifier("search.emptyState")
        }
    }

    /// 新画面構成 (2)「検索履歴」— shown instead of the plain "メールを検索"
    /// prompt state whenever there's at least one remembered query.
    @ViewBuilder
    private var historyOrPromptState: some View {
        if historyEntries.isEmpty {
            ContentUnavailableView(
                "メールを検索",
                systemImage: "magnifyingglass",
                description: Text("差出人・件名・本文から、すべてのアカウントを横断して検索します。\n「from:」「to:」「cc:」「subject:」でヘッダを絞り込めます。")
            )
            .accessibilityIdentifier("search.promptState")
        } else {
            historyList
        }
    }

    private var historyList: some View {
        List {
            Section {
                ForEach(historyEntries) { entry in
                    historyRow(for: entry)
                }
                .onDelete(perform: deleteHistoryEntries)
            } header: {
                Text("最近の検索")
            } footer: {
                Button("履歴をすべて削除", role: .destructive) { clearHistory() }
                    .font(OtegamiFont.caption())
                    .accessibilityIdentifier("search.history.clearAll")
            }
        }
        .accessibilityIdentifier("search.history.list")
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
    }

    private func historyRow(for entry: SearchHistoryRecord) -> some View {
        Button {
            searchText = entry.queryText
        } label: {
            Label(entry.queryText, systemImage: "clock")
        }
        .accessibilityIdentifier("search.history.row.\(entry.id ?? 0)")
    }

    /// 1d/design-phase-3: same "more than one account" gate as
    /// `MessageListView.showsAccountAccent`.
    private var showsAccountAccent: Bool {
        environment.accounts.count > 1
    }

    /// One row — a plain `Button` + `ThreadRowView`, not the fuller
    /// `MessageListRow` (no swipe/selection chrome here, see this type's
    /// doc comment).
    @ViewBuilder
    private func searchRow(for summary: ThreadSummary) -> some View {
        if let threadId = summary.thread.id {
            Button {
                selectedThreadId = threadId
                // スレッド表示オフ中はフラットな検索結果 (1メッセージ1行) —
                // `selectedMessageId`のdoc comment参照。
                selectedMessageId = summary.singleMessageId
            } label: {
                ThreadRowView(
                    summary: summary,
                    accountDisplayName: accountDisplayNames[summary.thread.accountId],
                    accountLabelColorKey: accountLabelColorKeys[summary.thread.accountId],
                    showsAccountAccent: showsAccountAccent
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search.row.\(threadId)")
            // Task #67: same iOS full-bleed treatment as `MessageListRow`
            // (this screen is iOS-only — `MailScreenView` only instantiates
            // it inside an `#if os(iOS)` block) — see its doc comment.
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    /// Same 300ms-debounce shape as `MessageListView.scheduleSearch()`
    /// (M7) — kept independent rather than shared since the two views'
    /// surrounding state (search scope picker, pagination) has already
    /// diverged enough that a shared helper would need its own parameters
    /// threaded through for no real duplication savings.
    private func scheduleSearch() {
        searchTask?.cancel()
        guard isActive else {
            isSearching = false
            results = []
            return
        }
        let query = searchText
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(query: query)
        }
    }

    private func performSearch(query: String) async {
        let accountIds = accountFilter.map { [$0] } ?? environment.accounts.map(\.id)
        do {
            // 実機バグ報告「スレッド表示をオフにしてるのに、スレッドで表示
            // されることがある」— 検索結果は`isThreadingEnabled`を無視して
            // 常にグループ化されたスレッドを返していた。`MessageListView
            // .performSearch`と同じ理由で`SearchQuery.flatMessageSummaries`
            // (このバッチで新設)に分岐する。
            let isFlat = !isThreadingEnabled
            let fetched = try await environment.database.dbWriter.read { db in
                isFlat
                    ? try SearchQuery.flatMessageSummaries(query: query, scope: .allAccounts(accountIds: accountIds), db: db)
                    : try SearchQuery.threadSummaries(query: query, scope: .allAccounts(accountIds: accountIds), db: db)
            }
            guard !Task.isCancelled else { return }
            results = fetched
            schedulePrefetch(for: fetched)
            try? await environment.database.dbWriter.write { db in
                try SearchHistoryQuery.record(query, db: db)
            }
            await loadHistory()
        } catch {
            guard !Task.isCancelled else { return }
            results = []
        }
        isSearching = false
    }

    // MARK: - Task #80: search-result-triggered background body prefetch

    /// Same debounce length/rationale as `MessageListView`'s identical
    /// property — this screen's own `scheduleSearch()` already debounces
    /// keystrokes by 300ms before a search even runs; this is a further,
    /// much longer debounce on top, for the background *prefetch* rather
    /// than the search itself (the user isn't waiting on this one).
    private static let listUpdatePrefetchDebounce: Duration = .seconds(3)

    @State private var prefetchTask: Task<Void, Never>?
    /// See `MessageListView.lastPrefetchedMessageIds`'s doc comment — same
    /// "skip a repeat call for an unchanged candidate set" role, kept as
    /// this screen's own `@State` rather than shared since the two views
    /// don't share any other state either.
    @State private var lastPrefetchedMessageIds: Set<Int64> = []

    /// Task #80 (「検索結果など、メール一覧が更新されたときに、バックグラウンド
    /// でメールを取得するようにしてほしい」): this screen's `performSearch`
    /// counterpart to `MessageListView.schedulePrefetch(for:)` — background-
    /// prefetches the leading `SyncCoordinator.listUpdatePrefetchLimit`
    /// not-yet-fetched messages among a just-landed set of search results,
    /// so opening a hit right after searching usually doesn't pay the
    /// on-open fetch's own network round trip. See that method's doc
    /// comment for the shared debounce/dedupe/best-effort behavior — this
    /// is a near-identical copy, not a shared helper, for the same "these
    /// two views' surrounding state has already diverged enough" reason
    /// `performSearch`'s own doc comment gives for not sharing
    /// `scheduleSearch()` either.
    private func schedulePrefetch(for results: [ThreadSummary]) {
        let candidateIds = results
            .compactMap(\.latestMessage)
            .filter { $0.bodyState != .fetched }
            .compactMap(\.id)
            .prefix(SyncCoordinator.listUpdatePrefetchLimit)
        guard !candidateIds.isEmpty else { return }
        let idSet = Set(candidateIds)
        guard idSet != lastPrefetchedMessageIds else { return }

        prefetchTask?.cancel()
        let ids = Array(candidateIds)
        prefetchTask = Task(priority: .background) {
            try? await Task.sleep(for: Self.listUpdatePrefetchDebounce)
            guard !Task.isCancelled else { return }
            lastPrefetchedMessageIds = idSet
            _ = await environment.prefetchMessageBodiesIfNeeded(messageIds: ids)
        }
    }

    private func loadHistory() async {
        historyEntries = (try? await environment.database.dbWriter.read { db in
            try SearchHistoryQuery.recent(db: db)
        }) ?? []
    }

    private func deleteHistoryEntries(at offsets: IndexSet) {
        let ids = offsets.compactMap { historyEntries[$0].id }
        Task {
            try? await environment.database.dbWriter.write { db in
                for id in ids { try SearchHistoryQuery.delete(id: id, db: db) }
            }
            await loadHistory()
        }
    }

    private func clearHistory() {
        Task {
            try? await environment.database.dbWriter.write { db in
                try SearchHistoryQuery.deleteAll(db: db)
            }
            await loadHistory()
        }
    }
}
