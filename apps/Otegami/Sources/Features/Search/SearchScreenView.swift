import SwiftUI
import OtegamiStore

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
            .navigationDestination(item: $selectedThreadId) { threadId in
                ThreadDetailView(threadId: threadId, onReply: onReply)
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
            } label: {
                ThreadRowView(
                    summary: summary,
                    accountDisplayName: accountDisplayNames[summary.thread.accountId],
                    showsAccountAccent: showsAccountAccent
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search.row.\(threadId)")
            // 表示・操作改善バッチ「カード状表示」: same margin-as-gap treatment
            // as `MessageListRow` — see its doc comment.
            .listRowInsets(EdgeInsets(top: OtegamiSpacing.xs, leading: OtegamiSpacing.sm, bottom: OtegamiSpacing.xs, trailing: OtegamiSpacing.sm))
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
            let fetched = try await environment.database.dbWriter.read { db in
                try SearchQuery.threadSummaries(query: query, scope: .allAccounts(accountIds: accountIds), db: db)
            }
            guard !Task.isCancelled else { return }
            results = fetched
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
