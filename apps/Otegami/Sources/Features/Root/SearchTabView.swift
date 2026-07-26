import SwiftUI
import OtegamiStore

/// iOS's "検索" tab (1a): "現在サイドバーに詰め込まれている導線（設定・検索）を
/// タブに移す" — this used to be `.searchable` embedded directly on
/// `MessageListView`'s list (M7); moving it to its own always-account-
/// spanning tab is this task's structural change. Reuses `ThreadRowView`
/// (the same 1d row `MessageListView`/`MessageListRow` render) so a search
/// hit looks identical to the same thread in the mail list, and
/// `ThreadQuery`/`SearchQuery` (`OtegamiStore`, M7) unchanged — only the
/// hosting screen is new.
///
/// Deliberately simpler than `MessageListView`: no swipe actions, no bulk
/// selection, no pagination beyond `SearchQuery`'s own built-in result cap
/// (`SearchQuery.defaultResultLimit`) — a search results screen's job is
/// "find the thread, open it," not full list-management chrome. Always
/// searches across every account (`SearchScope.allAccounts`); 1a's chip-
/// scoped "現在のメールボックス" concept doesn't apply here since this tab has
/// no mailbox selection of its own to scope to.
///
/// design-phase-3 (1j): adds the filter chip row (全部/添付/未読/英語 —
/// `SearchFilterOption`) and 人/メール sectioning on top of the M7 baseline
/// above; see those two properties' doc comments for how each works.
struct SearchTabView: View {
    @Environment(AppEnvironment.self) private var environment
    var onReply: (Int64, Bool, Bool) -> Void

    @State private var searchText = ""
    @State private var results: [ThreadSummary] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedThreadId: Int64?
    /// 1j's filter chip row — see `SearchFilterOption`'s doc comment on why
    /// this filters `results` client-side rather than re-querying.
    @State private var filter: SearchFilterOption = .all

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
    /// (name or address), "メール" otherwise (a subject/body match, per
    /// `SearchQuery`'s own FTS/LIKE matching — which field actually matched
    /// isn't returned by that query, so this reproduces just the sender
    /// half client-side, cheaply, from data already in hand). A thread
    /// whose sender happens to *also* share text with the query lands in
    /// "人" even if the subject matched too — an either/or bucket, not a
    /// perfect account of every reason a result matched, but the
    /// distinction the handoff cares about (finding a *person* vs. finding
    /// a *message*) still comes through. Documented as a deliberate
    /// approximation in `docs/design-system.md`'s design-phase-3 section.
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
            .searchable(text: $searchText, prompt: "差出人・件名・本文")
            .onChange(of: searchText) { _, _ in scheduleSearch() }
            .navigationDestination(item: $selectedThreadId) { threadId in
                ThreadDetailView(threadId: threadId, onReply: onReply)
            }
        }
        .tint(OtegamiColor.accent)
    }

    /// Split out of `body` (`docs/ci.md`'s type-check-timeout discipline —
    /// two `Section`s each with their own `ForEach`, inline in the same
    /// expression as the filter chip row and `.searchable`'s modifier
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

    @ViewBuilder
    private var overlayContent: some View {
        if !isActive {
            ContentUnavailableView(
                "メールを検索",
                systemImage: "magnifyingglass",
                description: Text("差出人・件名・本文から、すべてのアカウントを横断して検索します。")
            )
            .accessibilityIdentifier("search.promptState")
        } else if isSearching {
            ProgressView("検索中…")
                .accessibilityIdentifier("search.loading")
        } else if filteredResults.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .accessibilityIdentifier("search.emptyState")
        }
    }

    /// 1d/design-phase-3: same "more than one account" gate as
    /// `MessageListView.showsAccountAccent` — a search result can come from
    /// any account in principle, but with exactly one account configured
    /// the label/rail would always name that same single account, which is
    /// redundant noise rather than useful disambiguation (see that
    /// property's doc comment for the full reasoning).
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
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .otegamiRowDivider()
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
        let accountIds = environment.accounts.map(\.id)
        do {
            let fetched = try await environment.database.dbWriter.read { db in
                try SearchQuery.threadSummaries(query: query, scope: .allAccounts(accountIds: accountIds), db: db)
            }
            guard !Task.isCancelled else { return }
            results = fetched
        } catch {
            guard !Task.isCancelled else { return }
            results = []
        }
        isSearching = false
    }
}
