import SwiftUI
import OtegamiStore
import SyncEngine

/// iOS's 検索画面 (検索画面再構成 Task #86): presented as a sheet from
/// `MailScreenView`'s header search button, or from `ThreadDetailView`'s
/// footer toolbar「検索」button (opened with `presetQuery` already filled in
/// as `from:<差出人>` — "そのメールの from で絞り込まれた状態で開く").
///
/// **Task #86 (Sparkハンドオフ)**: 前バッチ (新画面構成) の`.searchable`＋
/// ナビゲーションバーの構成を、Sparkのスクリーンショットに合わせて総入れ
/// 替えした——
/// - **トップバー** (`SearchTopBar`): 角丸 (カプセル型) の`TextField`。先頭に
///   「現在のクエリ+フィルタ+アカウント絞りを保存」の星、右に丸い閉じる
///   ボタン (旧`search.closeButton`の役割をそのまま引き継ぐ)。システムの
///   `.searchable`をやめたのは、Sparkの参考画像が「フィールドの中に星
///   アイコンがある」独自レイアウトで、システム検索バーの装飾ではこの
///   形にできないため。
/// - **タブ「履歴」「保存済み」** (`SearchTabRow`): クエリが空のあいだだけ
///   表示。履歴は既存の検索履歴 (`SearchHistoryQuery`) をそのまま流用、
///   保存済みは今回の新機能 (`SavedSearchQuery`)。
/// - **チップの表示条件**: アカウント絞り込み・フィルタチップは「入力中
///   または結果表示時」(`isActive`) だけ表示し、タブ表示中は出さない —
///   Sparkの空状態がチップ無しだったことに合わせた。
///
/// 検索そのもの (演算子・FTS・フィルタの挙動) は前バッチから不変 ——
/// **検索演算子** `from:`/`to:`/`cc:`/`subject:` — `SearchQuery.parse(_:)`
/// がトークンを演算子とフリーテキストに分割し、
/// `SearchQuery.threadSummaries(parsed:scope:limit:db:)` が両者を
/// `Set<Int64>` の積集合として組み合わせる (AND 条件)。
///
/// Reuses `ThreadRowView` (the same 1d row `MessageListView`/
/// `MessageListRow` render) so a search hit looks identical to the same
/// thread in the mail list.
///
/// Deliberately simpler than `MessageListView`: no swipe actions, no bulk
/// selection, no pagination beyond `SearchQuery`'s own built-in result cap
/// (`SearchQuery.defaultResultLimit`) — a search results screen's job is
/// "find the thread, open it," not full list-management chrome.
///
/// **検索の IMAP サーバーサイド SEARCH フォールバック**: 検索はローカル DB
/// (`SearchQuery`) だけを見るため、まだ同期されていない古いメール・本文
/// 未ダウンロードのメールはヒットしない。`resultsSections`の末尾に常に
/// (結果 0 件のときも) `ServerSearchTriggerRow`「サーバーで検索」行を表示し
/// — 自動発動しない、タップが唯一のトリガー — `runServerSearch()`が
/// `AppEnvironment.serverSearch(query:accountIds:)`
/// (`SyncCoordinator.serverSearch`への薄い配線) を呼ぶ。返ってきた
/// `ThreadSummary`はローカル FTS で再フィルタせずそのまま「サーバー検索
/// 結果」セクションに表示する — サーバーが返した ID 集合が正 (本文マッチは
/// ローカル索引に無いことがあるため)。クエリ/アカウント絞りが変わるたびに
/// `resetServerSearchState()`が前回の結果を破棄する。
struct SearchScreenView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    var onReply: (Int64, Bool) -> Void
    /// Set by a caller that already knows what to search for (メール本文
    /// 画面の「検索」ツールバーボタン) — applied once, on appear, then this
    /// view's own `searchText` state takes over.
    var presetQuery: String?

    @State private var searchText = ""
    @State private var results: [ThreadSummary] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    /// 検索の IMAP サーバーサイド SEARCH フォールバック (`ServerSearchTriggerRow`):
    /// `nil` = まだこのクエリでサーバー検索を実行していない — 自動発動しない
    /// ので、ユーザーがタップするまでこのまま。ローカル FTS で再フィルタ
    /// しない (`performServerSearch`のドキュメントコメント参照) — サーバーが
    /// 返した`ThreadSummary`をそのまま表示する。
    @State private var serverSearchResults: [ThreadSummary]?
    @State private var isServerSearching = false
    @State private var serverSearchErrorMessage: String?
    @State private var serverSearchTask: Task<Void, Never>?
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
    /// Task #86: 保存済み検索の一覧 — 常に`SavedSearchQuery.maxEntries`以下
    /// なので、丸ごとメモリに持って「現在の検索は保存済みか」の判定
    /// (`isCurrentQuerySaved`) にもそのまま流用する (DB往復を増やさない)。
    @State private var savedEntries: [SavedSearchRecord] = []
    /// Task #86: クエリが空のあいだ表示するタブ。
    @State private var selectedTab: SearchTab = .history

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

    /// Task #86: 現在のクエリ+フィルタ+アカウント絞りが、既に`savedEntries`
    /// のどれかと一致するか — 星の塗りつぶし状態はこれをそのまま反映する。
    /// `savedEntries`はDB全体を常に丸ごと持っている (`SavedSearchQuery
    /// .maxEntries`以下しか無い) ので、追加のDB往復無しに計算できる。
    private var isCurrentQuerySaved: Bool {
        guard isActive else { return false }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return savedEntries.contains {
            $0.queryText == trimmed && $0.filter == filter.rawValue && $0.accountId == accountFilter
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SearchTopBar(
                    searchText: $searchText,
                    isSaved: isCurrentQuerySaved,
                    isSaveEnabled: isActive,
                    onToggleSaved: toggleSaved,
                    onClose: { dismiss() }
                )
                if isActive {
                    if environment.accounts.count > 1 {
                        SearchAccountFilterChipRow(accounts: environment.accounts, selectedAccountId: $accountFilter)
                    }
                    SearchFilterChipRow(selection: $filter)
                } else {
                    SearchTabRow(selection: $selectedTab)
                }
                listArea
            }
            .background(OtegamiColor.background)
            // Task #86: システム検索バー/ナビゲーションタイトルの代わりに
            // `SearchTopBar`を使うので、この画面のナビゲーションバー自体は
            // 隠す — 押し先の`ThreadEntryView`はこの画面と別のスコープなので
            // 自身のバーは通常どおり表示される。`ToolbarPlacement
            // .navigationBar`はmacOSには無い (この型自体はマルチプラット
            // フォームターゲットの一部としてmacOS destinationでもコンパイル
            // される — `SearchScreenView`をインスタンス化するのは
            // `MailScreenView`の`#if os(iOS)`ブロックの中だけだが、この
            // ファイル自体はどちらのプラットフォームでもビルドされる) ため
            // `#if os(iOS)`で囲む。
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
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
        .task {
            await loadHistory()
            await loadSavedSearches()
        }
        .onAppear {
            guard let presetQuery, searchText != presetQuery else { return }
            searchText = presetQuery
        }
    }

    /// この画面の唯一の`List` — `isActive`/`selectedTab`に応じて中身
    /// (`listContent`) だけが差し替わり、`accessibilityIdentifier`は常に
    /// `search.list`のまま (UITestの「検索画面が開けば`search.list`は必ず
    /// 存在する」という前提を維持する — 空状態も`overlay`で重ねるだけで
    /// `List`自体は消さない、旧`resultsList`/`overlayContent`と同じ流儀)。
    /// Split out of `body` (`docs/ci.md`'s type-check-timeout discipline)。
    private var listArea: some View {
        List { listContent }
            .accessibilityIdentifier("search.list")
            .scrollContentBackground(.hidden)
            .background(OtegamiColor.background)
            .overlay { listOverlayContent }
    }

    /// `historySection`/`savedSection`は空のときは丸ごと描画しない (`if
    /// !historyEntries.isEmpty { historySection }`) — `Section`の
    /// header/footer ("最近の検索"「履歴をすべて削除」等) は中身の`ForEach`が
    /// 0件でも描画されてしまうため、そのまま出すと`listOverlayContent`の
    /// 空状態と二重表示になる。`resultsSections`が空のとき何も描画しない
    /// (`if !peopleResults.isEmpty`/`if !mailResults.isEmpty`) のと同じ
    /// 流儀。
    @ViewBuilder
    private var listContent: some View {
        if isActive {
            resultsSections
        } else if selectedTab == .history {
            if !historyEntries.isEmpty {
                historySection
            }
        } else {
            if !savedEntries.isEmpty {
                savedSection
            }
        }
    }

    private var resultsSections: some View {
        Group {
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
            serverSearchSection
        }
    }

    /// 検索の IMAP サーバーサイド SEARCH フォールバック: ローカル検索結果の
    /// 末尾に常に表示する (結果 0 件のときも) — `ServerSearchTriggerRow`
    /// (未実行/実行中/エラーの見た目) + 実行済みならヒットのセクション。
    /// ヒットは`ThreadRowView`をそのまま使う既存の`searchRow(for:)`を再利用
    /// し、ローカル FTS で再フィルタしない (`filteredResults`/`peopleResults`/
    /// `mailResults`のようなクライアント側フィルタを一切通さず、サーバーが
    /// 返した`ThreadSummary`をそのまま並べる)。
    @ViewBuilder
    private var serverSearchSection: some View {
        Section {
            ServerSearchTriggerRow(
                isSearching: isServerSearching,
                errorMessage: serverSearchErrorMessage,
                onTap: runServerSearch
            )
        }
        if let serverSearchResults, !serverSearchResults.isEmpty {
            Section("サーバー検索結果") {
                ForEach(serverSearchResults) { summary in
                    searchRow(for: summary)
                }
            }
        }
    }

    private var historySection: some View {
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

    private var savedSection: some View {
        Section {
            ForEach(savedEntries) { entry in
                savedRow(for: entry)
            }
            .onDelete(perform: deleteSavedEntries)
        } header: {
            Text("保存済みの検索")
        }
    }

    /// Kept as an `.overlay` on top of (not a row *inside*) `search.list` —
    /// matching M7's original design — so `search.list.cells.count` stays a
    /// reliable "how many real result rows" signal for both the loading
    /// state and the zero-results state, not just the history/saved lists.
    @ViewBuilder
    private var listOverlayContent: some View {
        if isActive {
            if isSearching {
                ProgressView("検索中…")
                    .accessibilityIdentifier("search.loading")
            }
            // 検索の IMAP サーバーサイド SEARCH フォールバック: ローカル結果が
            // 0件でも`resultsSections`末尾の`ServerSearchTriggerRow`
            // (「サーバーで検索」行) を必ず表示するようになったため、ここでは
            // もう`ContentUnavailableView.search`を overlay として出さない —
            // overlay はその行の上に重なって隠してしまい、タップできなく
            // なる。ローカルに一致が無いことは、そのトリガー行のサブタイトル
            // (「ローカルに無い古いメールもサーバー上で検索します」) 自体が
            // 説明する。
        } else if selectedTab == .history {
            if historyEntries.isEmpty {
                ContentUnavailableView(
                    "検索履歴はありません",
                    systemImage: "clock",
                    description: Text("差出人・件名・本文から、すべてのアカウントを横断して検索します。\n「from:」「to:」「cc:」「subject:」でヘッダを絞り込めます。")
                )
                .accessibilityIdentifier("search.history.emptyState")
            }
        } else {
            if savedEntries.isEmpty {
                ContentUnavailableView(
                    "保存した検索はありません",
                    systemImage: "star",
                    description: Text("検索フィールド左の星をタップすると、今の検索条件 (クエリ・絞り込み・アカウント) を名前を付けずに保存できます。")
                )
                .accessibilityIdentifier("search.saved.emptyState")
            }
        }
    }

    private func historyRow(for entry: SearchHistoryRecord) -> some View {
        Button {
            searchText = entry.queryText
        } label: {
            // `Label(entry.queryText, systemImage:)`にしない理由:
            // `AccountFilterChip.label`のドキュメントコメント参照 —
            // `Label(_:systemImage:)`の第1引数は`LocalizedStringKey`であり、
            // 保存された検索文字列がメールアドレスそのものだと SwiftUI が
            // Markdown 経由で自動的に`mailto:`リンク化してしまう実機バグの
            // 経路を踏む。動的文字列は`Text(verbatim:)`で素通しする。
            HStack(spacing: OtegamiSpacing.sm) {
                Image(systemName: "clock")
                    .foregroundStyle(OtegamiColor.inkSecondary)
                Text(verbatim: entry.queryText)
                    .foregroundStyle(OtegamiColor.ink)
            }
        }
        .accessibilityIdentifier("search.history.row.\(entry.id ?? 0)")
    }

    private func savedRow(for entry: SavedSearchRecord) -> some View {
        Button {
            applySavedSearch(entry)
        } label: {
            SavedSearchRow(entry: entry, accountDisplayName: entry.accountId.flatMap { accountDisplayNames[$0] })
        }
        .accessibilityIdentifier("search.saved.row.\(entry.id ?? 0)")
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
        // 検索の IMAP サーバーサイド SEARCH フォールバック: クエリ/アカウント
        // 絞りが変わるたびに前回のサーバー検索結果は無効 — 古いクエリの
        // ヒットを新しいクエリの画面に残さない (`resetServerSearchState`の
        // doc comment参照)。
        resetServerSearchState()
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

    // MARK: - 検索の IMAP サーバーサイド SEARCH フォールバック

    /// クエリ/アカウント絞りが変わるたびに呼ぶ — 進行中のサーバー検索が
    /// あれば取り消し、前回のクエリの結果/エラー表示を一掃する。自動発動
    /// しない機能なので、ここでは新しいサーバー検索を*始めない* — 次に
    /// `ServerSearchTriggerRow`がタップされるまで`serverSearchResults`は
    /// `nil`のまま (トリガー行だけが常に表示される)。
    private func resetServerSearchState() {
        serverSearchTask?.cancel()
        serverSearchTask = nil
        isServerSearching = false
        serverSearchResults = nil
        serverSearchErrorMessage = nil
    }

    /// `ServerSearchTriggerRow`のタップハンドラ — ローカル検索結果に無い
    /// ヒットを探すため、現在のクエリ/アカウント絞りで IMAP `SEARCH`を
    /// 実行する。`SyncCoordinator.serverSearch`が返す`ThreadSummary`を
    /// ローカル FTS で再フィルタせずそのまま`serverSearchResults`に置く
    /// (本文マッチはローカル索引に無いことがあるため — このファイル冒頭の
    /// doc comment参照)。
    private func runServerSearch() {
        guard isActive, !isServerSearching else { return }
        let query = searchText
        let accountIds = accountFilter.map { [$0] } ?? []
        isServerSearching = true
        serverSearchErrorMessage = nil
        serverSearchTask = Task {
            let outcome = await environment.serverSearch(query: query, accountIds: accountIds)
            guard !Task.isCancelled else { return }
            serverSearchResults = outcome.summaries
            if !outcome.failedAccountIds.isEmpty {
                serverSearchErrorMessage = outcome.timedOut
                    ? "一部のアカウントで検索がタイムアウトしました"
                    : "一部のアカウントで検索に失敗しました"
            } else if outcome.timedOut {
                serverSearchErrorMessage = "検索がタイムアウトしました"
            }
            isServerSearching = false
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
            // Task #82: `!isThreadingEnabled`(`@AppStorage`のキャッシュ値)
            // ではなく`UserDefaults`から直接読み直す — `MessageListView
            // .isFlatMode`と同じ理由 (`ListDisplaySettingsStore
            // .persistedBool(forKey:default:)`のdoc comment参照)。
            let isFlat = !ListDisplaySettingsStore.persistedBool(forKey: ListDisplaySettingsStore.threadingKey, default: ListDisplaySettingsStore.defaultThreading)
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

    // MARK: - Task #86: saved searches

    private func loadSavedSearches() async {
        savedEntries = (try? await environment.database.dbWriter.read { db in
            try SavedSearchQuery.recent(db: db)
        }) ?? []
    }

    /// 検索フィールド先頭の星タップ — 現在のクエリ+フィルタ+アカウント絞りが
    /// 既に保存済みなら解除、未保存なら保存する (`SavedSearchQuery.toggle`
    /// がそのままトグル)。クエリが空 (`isActive == false`) の間は
    /// `SearchTopBar`側で無効化済みだが、念のためここでも同じガードを持つ。
    private func toggleSaved() {
        guard isActive else { return }
        let query = searchText
        let currentFilter = filter.rawValue
        let currentAccount = accountFilter
        Task {
            do {
                try await environment.database.dbWriter.write { db in
                    try SavedSearchQuery.toggle(queryText: query, filter: currentFilter, accountId: currentAccount, db: db)
                }
                await loadSavedSearches()
            } catch {
                // ベストエフォート — `loadHistory`/`clearHistory`と同じ判断:
                // 保存の失敗はこの画面の主機能 (検索そのもの) をブロック
                // しない。
            }
        }
    }

    /// 保存済み検索の行タップ — クエリ・フィルタ・アカウント絞りを一括で
    /// 再適用する。`searchText`を最後に設定するのは、それが`onChange`で
    /// `scheduleSearch()`を起動する唯一のトリガーであり、その時点で
    /// `filter`/`accountFilter`が既に新しい値になっている必要があるため。
    private func applySavedSearch(_ entry: SavedSearchRecord) {
        accountFilter = entry.accountId
        filter = SearchFilterOption.persisted(rawValue: entry.filter)
        searchText = entry.queryText
    }

    private func deleteSavedEntries(at offsets: IndexSet) {
        let ids = offsets.compactMap { savedEntries[$0].id }
        Task {
            try? await environment.database.dbWriter.write { db in
                for id in ids { try SavedSearchQuery.delete(id: id, db: db) }
            }
            await loadSavedSearches()
        }
    }
}
