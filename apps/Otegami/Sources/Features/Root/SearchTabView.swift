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
struct SearchTabView: View {
    @Environment(AppEnvironment.self) private var environment
    var onReply: (Int64, Bool) -> Void

    @State private var searchText = ""
    @State private var results: [ThreadSummary] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedThreadId: Int64?

    private var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var accountDisplayNames: [String: String] {
        Dictionary(uniqueKeysWithValues: environment.accounts.map { ($0.id, $0.displayName) })
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { summary in
                    searchRow(for: summary)
                }
            }
            .accessibilityIdentifier("search.list")
            .scrollContentBackground(.hidden)
            .background(OtegamiColor.background)
            .overlay { overlayContent }
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
        } else if results.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .accessibilityIdentifier("search.emptyState")
        }
    }

    /// One row — a plain `Button` + `ThreadRowView`, not the fuller
    /// `MessageListRow` (no swipe/selection chrome here, see this type's
    /// doc comment). `showsAccountAccent: true` unconditionally: a search
    /// result can come from any account, so the rail/trailing label always
    /// earn their place here, unlike a single already-selected mailbox.
    @ViewBuilder
    private func searchRow(for summary: ThreadSummary) -> some View {
        if let threadId = summary.thread.id {
            Button {
                selectedThreadId = threadId
            } label: {
                ThreadRowView(
                    summary: summary,
                    accountDisplayName: accountDisplayNames[summary.thread.accountId],
                    showsAccountAccent: true
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
