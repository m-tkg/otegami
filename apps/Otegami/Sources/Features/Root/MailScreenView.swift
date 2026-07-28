import SwiftUI
import OtegamiStore

/// iOS's sole always-visible screen (新画面構成 (1)): a plain title (「すべての
/// 受信」等 — no longer tappable, see below) → `AccountFilterChipRow` (only
/// meaningful while the unified inbox is selected) → `MessageListView`,
/// wrapped in `HamburgerMenuContainer` so `FolderListSheet`'s folder-
/// navigation content (統合受信トレイ／アカウント別ツリー／下書き等／設定) can
/// slide in from the leading edge instead of presenting as a modal sheet.
/// Owns the one piece of navigation state `MessageListView` itself no
/// longer does on iOS (`navigationTitle`/`.searchable` moved out — see that
/// view's doc comment): which mailbox is selected, which account the filter
/// chips narrow to, and which thread (if any) is pushed.
///
/// 旧「ナビタイトルのタップでフォルダシートを開く」動線はハンバーガーボタンに
/// 置き換えた (`CLAUDE.md`) — タイトル自体は素の `Text` に戻り、フォルダ切替は
/// 常に左上のハンバーガーアイコンから。検索は一覧画面左下のフローティング
/// ボタン (`floatingSearchButton`、`FolderListSheet.floatingSettingsButton`と
/// 同じ「常にスクロール位置に関わらず見えている」流儀) から `SearchScreenView`
/// をシート表示する — ヘッダの再読込ボタンは廃止 (pull-to-refresh に一本化、
/// `MessageListView`側) し、空いたヘッダには「未読のみ表示」トグル
/// (`unreadOnlyToggleButton`) を追加した。
struct MailScreenView: View {
    @Environment(AppEnvironment.self) private var environment
    /// Task #70 (ユーザー要望「iPad 版など、横長の場合は必ず左側にメール
    /// 一覧、右側にメール本文という形にして」): iPad の全画面/大きめ
    /// Split View、iPhone の横向き Plus/Max 系など horizontal size class が
    /// `.regular` の間だけ `regularSplitView` (2カラム `NavigationSplitView`)
    /// に切り替える — `.compact` (iPhone 縦向き、iPad の狭い Split View/
    /// Slide Over) は従来どおり `compactNavigationStack` の単一カラム push
    /// 遷移のまま。`docs/design-system.md`の「Task #70」節に、`CLAUDE.md`の
    /// 「1a はコンパクト幅向けの設計」という記述をこの分岐でどう扱うかの
    /// 判断を記録した。macOS では `horizontalSizeClass` は常に`nil`
    /// (AppKit にサイズクラスの概念が無い) だが、この型自体が
    /// `OtegamiRootView`のdoc comment通りiOS専用でmacOSからは never
    /// instantiated なので実害はない。
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var onCompose: () -> Void
    var onOpenDraft: (Int64) -> Void
    var onOpenServerDraft: (Int64) -> Void
    var onReply: (Int64, Bool, Bool) -> Void
    /// 新画面構成 (3): メール本文画面フッターツールバーの「転送」。
    var onForward: (Int64) -> Void
    /// C7: reopens the Composer with a just-cancelled pending send's fields
    /// — see `handleCancelPendingSend()`.
    var onOpenCancelledSend: (PendingSendDraftSnapshot) -> Void

    @State private var mailSelection: SidebarSelection = .unifiedInbox
    @State private var accountFilter: String?
    // `Text(selectionTitle)`はverbatim呼び出しになるため、代入箇所すべてで
    // `String(localized:)`を使う (このプロパティの唯一の消費者である
    // `Text(selectionTitle)`呼び出し自体はそのまま)。
    @State private var selectionTitle = String(localized: "すべての受信")
    @State private var selectedThreadId: Int64?
    /// 実機フィードバック第3弾 (A) — see `MessageListView.selectedMessageId`'s
    /// doc comment. Written alongside `selectedThreadId` on every tap;
    /// forwarded to `ThreadDetailView.singleMessageId` in
    /// `.navigationDestination(item:)` below.
    @State private var selectedMessageId: Int64?
    @State private var isSelecting = false
    /// G「削除・アーカイブ時の挙動」— see `MessageListView.onSummariesChanged`'s
    /// doc comment: the most recently observed on-screen thread order,
    /// refreshed on every `MessageListView` re-render, consulted by
    /// `handleThreadRemoved(_:)` to resolve "next message" navigation.
    /// Task #74 でも二つ目の消費者として使う: `.count`をタイトル横の件数表示
    /// (`toolbarContent`) にそのまま流用する — 新規の観測を増やさずに済む
    /// (詳細はその使用箇所のdoc comment参照)。
    @State private var currentThreadOrder: [Int64] = []
    @AppStorage(MessagePostActionSettingsStore.afterDeleteArchiveKey) private var postDeleteArchiveActionRaw = MessagePostActionSettingsStore.defaultAfterDeleteArchive.rawValue

    /// ハンバーガーメニュー (フォルダ／設定) の開閉。
    @State private var isMenuOpen = false
    @State private var accountEntryRoute: AccountEntryRoute?
    @State private var showingOutbox = false
    @State private var showingDrafts = false
    @State private var showingFailedOps = false
    @State private var showingMailboxSyncFailures = false
    @State private var showingSettings = false

    /// 新画面構成 (2): ヘッダの検索ボタン、またはメール本文画面フッターツール
    /// バーの「検索」(差出人でプリセット) から開く。`searchPresetQuery` が
    /// non-nil のときだけ `SearchScreenView` に初期値として渡す — 通常の検索
    /// ボタンは常に `nil` (空の状態で開く)。
    @State private var showingSearch = false
    @State private var searchPresetQuery: String?

    /// ヘッダの「未読のみ表示」トグル — `ListDisplaySettingsStore.unreadOnlyKey`
    /// を`MessageListView`と共有する (どちらも同じ`UserDefaults`キーへの
    /// `@AppStorage`; 一方の変更がもう一方に伝わるのは`@AppStorage`自体の
    /// 挙動で、明示的な受け渡しは不要)。トグル自体をヘッダ (`MailScreenView`)
    /// に置き、絞り込みの実行を`MessageListView`側に置くのは、ヘッダの所有者
    /// が`MailScreenView`である一方、`ThreadQuery`呼び出しを組み立てる
    /// `observeThreads()`は`MessageListView`側にしかないため。検索画面
    /// (`SearchScreenView`) はこのキーを一切参照しない — 「検索画面には
    /// 影響させない」という要件どおり、`SearchQuery`は別の経路。
    @AppStorage(ListDisplaySettingsStore.unreadOnlyKey) private var isUnreadOnly = ListDisplaySettingsStore.defaultUnreadOnly

    /// Task #77 (ユーザー要望「アカウントごとにグルーピングする設定」): 未読
    /// のみトグルの隣に置く「アカウントでグループ化」トグル —
    /// `ListDisplaySettingsStore.groupByAccountKey`を`MessageListView`と共有
    /// する同じ`@AppStorage`の流儀 (`isUnreadOnly`のdoc comment参照)。実際の
    /// グルーピング (セクション分割) は`MessageListView.isGroupingActive`/
    /// `groupedSummaries`側で行う — ここはトグルの表示/書き込みだけ。
    @AppStorage(ListDisplaySettingsStore.groupByAccountKey) private var isGroupByAccount = ListDisplaySettingsStore.defaultGroupByAccount

    var body: some View {
        HamburgerMenuContainer(isOpen: $isMenuOpen) {
            menuContent
        } content: {
            mailContent
        }
        // Task #56 — see `AppEnvironment.uitestDirectOpenThreadId`'s doc
        // comment. `.task` (not `.onAppear`) so this doesn't fight
        // `@Observable`'s own dispatch timing; runs once per this view's
        // lifetime, which is exactly "once per app launch" since this view
        // is never torn down and recreated while the app is running. A
        // no-op (`environment.uitestDirectOpenThreadId == nil`) on every
        // real launch.
        .task {
            if let threadId = environment.uitestDirectOpenThreadId {
                selectedThreadId = threadId
            }
            // Task #60 (シミュレータ検証基盤の整備): same "tap-free direct
            // navigation" idea as `uitestDirectOpenThreadId` above, for the
            // 設定画面 — there's no fake-fixture DB row to key off of here,
            // so this reads a plain launch *argument* (matching
            // `OtegamiApp.uiTestsShouldAutoAdvanceToContent`'s
            // `-uiTestsAutoAdvanceToContent`, not an `OTEGAMI_UITEST_*`
            // launch *environment* variable) instead. Lets
            // `scripts/verify-screen.sh` reach `SettingsSheetView` via a
            // plain `xcrun simctl launch ... -uitestsOpenSettingsDirectly`,
            // with no hamburger-menu-button tap needed.
            if ProcessInfo.processInfo.arguments.contains("-uitestsOpenSettingsDirectly") {
                showingSettings = true
            }
            // Task #78: 同じ「タップ不要の直接遷移」パターンで、ハンバー
            // ガーメニュー (`FolderListSheet`、左下の`floatingSettingsButton`
            // が乗っている画面) を`scripts/verify-screen.sh`から開けるように
            // する — アクセント塗り統一の見た目確認用 (`-uitestsOpenSettingsDirectly`
            // 同様、実機/通常起動では`-uitestsOpenFolderMenuDirectly`引数が
            // 無いので常にno-op)。
            if ProcessInfo.processInfo.arguments.contains("-uitestsOpenFolderMenuDirectly") {
                isMenuOpen = true
            }
        }
    }

    /// Task #70: `HamburgerMenuContainer`の`content`にはこの一つだけを渡す
    /// — 中身が`compactNavigationStack`/`regularSplitView`のどちらであって
    /// も、共通の状態 (`accountEntryRoute`/`showingOutbox`等) が駆動する
    /// シート群はここで一度だけ付ける (どちらの分岐でも同じ`.sheet`群が
    /// 要る一方、分岐のたびに複製すると片方だけ直し忘れる不整合の元になる
    /// ため)。`.tint`もここに一本化 (以前は`mailNavigationStack`自身に
    /// 付いていたのを、両分岐の共通祖先であるこの階層に上げただけ)。
    private var mailContent: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularSplitView
            } else {
                compactNavigationStack
            }
        }
        .tint(OtegamiColor.accent)
        .sheet(item: $accountEntryRoute) { route in
            accountEntryDestination(for: route, binding: $accountEntryRoute)
        }
        .sheet(isPresented: $showingOutbox) { OutboxView() }
        .sheet(isPresented: $showingDrafts) {
            DraftsView(onOpenDraft: onOpenDraft, onOpenServerDraft: onOpenServerDraft)
        }
        .sheet(isPresented: $showingFailedOps) { FailedOperationsView() }
        .sheet(isPresented: $showingMailboxSyncFailures) { MailboxSyncFailuresView() }
        .sheet(isPresented: $showingSettings) { SettingsSheetView() }
        .sheet(isPresented: $showingSearch, onDismiss: { searchPresetQuery = nil }) {
            SearchScreenView(onReply: onReply, presetQuery: searchPresetQuery)
        }
    }

    /// `.compact` (iPhone 縦向き、iPad の狭い Split View/Slide Over) —
    /// 従来どおり単一カラムの`NavigationStack`で、選択中のスレッド
    /// (`selectedThreadId`) を`.navigationDestination(item:)`でpushする。
    /// `regularSplitView`からこちらへサイズクラスが遷移してきたとき
    /// (回転・Split View のリサイズ・Stage Manager) も、`selectedThreadId`
    /// は`MailScreenView`自身の`@State`でありこの分岐の切り替え自体では
    /// リセットされないため、非nilならこの`.navigationDestination(item:)`
    /// が初回appearanceの時点で即座にpushする — 結果として「本文が
    /// push済みの状態で表示される」(Task #70の要件4) を追加コード無しで
    /// 満たす。`environment.uitestDirectOpenThreadId`が同じ仕組みで
    /// deep-linkしているのと同じ挙動。
    private var compactNavigationStack: some View {
        NavigationStack {
            content
                .toolbar { toolbarContent }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .navigationDestination(item: $selectedThreadId) { threadId in
                    ThreadEntryView(
                        threadId: threadId, preselectedMessageId: selectedMessageId, onReply: onReply, onForward: onForward,
                        onSearchFromSender: { query in openSearch(presetQuery: query) },
                        onThreadRemoved: handleThreadRemoved
                    )
                }
        }
    }

    /// `.regular` (iPad 全画面/大きめ Split View、iPhone 横向き Plus/Max 系):
    /// 左=`listColumn`(現行の一覧+ヘッダのトグル類+フローティング検索/作成、
    /// `content`/`toolbarContent`をそのまま流用)、右=`detailColumn`(選択中
    /// スレッドの本文、未選択時はプレースホルダ)。フォルダ切替は3カラム化
    /// せず、`compactNavigationStack`と同じ`HamburgerMenuContainer`のドロワー
    /// をそのまま流用する (`docs/design-system.md`のTask #70節に判断を記録)
    /// — `mailContent`がこの`regularSplitView`ごと`HamburgerMenuContainer
    /// .content`に渡っているので、ハンバーガーボタン (`listColumn`の
    /// `toolbarContent`内) を押せば2ペインの上に同じドロワーが重なる。
    private var regularSplitView: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            listColumn
        } detail: {
            detailColumn
        }
    }

    private var listColumn: some View {
        NavigationStack {
            content
                .toolbar { toolbarContent }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
    }

    /// 右ペイン — Task #70要件3「スレッド選択画面(2通以上)は右ペイン内で
    /// 選択画面→本文のpush」: `ThreadEntryView`自身が持つ
    /// `.navigationDestination(item:)`(`ThreadSelectionView`→
    /// `ThreadDetailView`) がこの`NavigationStack`の中で完結する。
    private var detailColumn: some View {
        NavigationStack {
            Group {
                if let selectedThreadId {
                    ThreadEntryView(
                        threadId: selectedThreadId, preselectedMessageId: selectedMessageId, onReply: onReply, onForward: onForward,
                        onSearchFromSender: { query in openSearch(presetQuery: query) },
                        onThreadRemoved: handleThreadRemoved
                    )
                } else {
                    ContentUnavailableView(
                        "メッセージが選択されていません",
                        systemImage: "envelope.open"
                    )
                    .accessibilityIdentifier("mail.detailEmptyState")
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // C7 送信キャンセル: "ヘッダのすぐ下に青いカウントダウンバー" — the
            // toolbar/nav title is chrome above this `NavigationStack`
            // content, so the first row of this `VStack` reads as directly
            // below it.
            if let pending = environment.pendingSendCoordinator.pendingSend {
                SendCountdownBar(pending: pending, onCancel: handleCancelPendingSend)
            }
            if isUnifiedInboxSelected, !environment.accounts.isEmpty {
                AccountFilterChipRow(accounts: environment.accounts, selectedAccountId: $accountFilter)
            }
            if environment.accounts.isEmpty {
                emptyState
            } else {
                MessageListView(
                    selection: mailSelection,
                    unifiedInboxAccountFilter: accountFilter,
                    selectedThreadId: $selectedThreadId,
                    selectedMessageId: $selectedMessageId,
                    onSelectionModeChanged: { isSelecting = $0 },
                    onSummariesChanged: { currentThreadOrder = $0 }
                )
            }
        }
        .background(OtegamiColor.background)
        // 一覧のスクロール位置に関わらず常に同じ場所にある方が押しやすい —
        // `FolderListSheet.floatingSettingsButton`と同じ「`overlay`+左下
        // 固定」パターン (ヘッダの虫眼鏡ボタンからの移設、実装ルール参照)。
        // 選択モード中はヘッダ自体が丸ごとキャンセル/選択数/全選択に
        // 差し替わる (`toolbarContent`) が、フローティングボタン自体は
        // `content`側にあるため`isSelecting`と無関係に出続ける — ボタンが
        // 一括操作の邪魔にならないよう非表示にする。
        .overlay(alignment: .bottomLeading) {
            if !isSelecting {
                floatingSearchButton
            }
        }
        // ユーザー要望: 「メールの新規作成ボタンは、ヘッダ部ではなく右下に
        // フローティングして欲しい」— 左下の`floatingSearchButton`と対に
        // なる配置。`MessageListView`の`List`は既に`.contentMargins(.bottom:
        // )`でこの高さぶんの余白を確保済み (検索ボタンのために追加済みの
        // 余白を両ボタンで共有するだけで、追加の余白は不要 — 左右どちらの
        // フローティングボタンも同じ縦位置にあるため)。
        .overlay(alignment: .bottomTrailing) {
            if !isSelecting {
                floatingComposeButton
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("アカウントがありません", systemImage: "envelope.badge")
        } description: {
            Text("メールアカウントを追加してください。")
        } actions: {
            Button("アカウントを追加") { presentAddAccount() }
                .accessibilityIdentifier("mail.addAccountButton")
        }
    }

    private var isUnifiedInboxSelected: Bool {
        if case .unifiedInbox = mailSelection { return true }
        return false
    }

    /// Task #77: 「アカウントでグループ化」トグル自体を出すかどうか —
    /// `MessageListView.showsAccountAccent`と同じ条件をこの画面側の状態
    /// (`mailSelection`/`accountFilter`) から再現する。単一メールボックス
    /// 選択中 (`.mailbox`) や、1a のアカウント絞り込みチップで1アカウントに
    /// 絞った統合受信トレイ、アカウントが1つしか無い場合は、グルーピング
    /// しても全行が同じアカウントで意味が無いのでトグル自体を隠す
    /// (ユーザー要望「単一アカウントのメールボックス表示時はトグルを出さない」)。
    private var showsGroupByAccountToggle: Bool {
        switch mailSelection {
        case .unifiedInbox:
            guard accountFilter == nil else { return false }
        case .unifiedRole:
            break
        case .mailbox:
            return false
        }
        return environment.accounts.count > 1
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !isSelecting {
            ToolbarItem(placement: .navigation) {
                hamburgerButton
            }
            ToolbarItem(placement: .principal) {
                // Task #74: タイトル横に「今表示されてる件数」— 新規の観測を
                // 増やさず、G「削除・アーカイブ時の挙動」用に元々
                // `onSummariesChanged`から受け取っている`currentThreadOrder`
                // (スレッド集約時はスレッド数、フラット表示時はメッセージ数、
                // 未読のみトグルON時はその絞り込み後の件数 — `MessageListView
                // .summaries`をそのまま映した配列なので、要件の3ケースすべて
                // 追加コード無しで満たす) の件数をそのまま流用する。ページング
                // (`MessageListView.pageLimit`)で切られた「現在読み込み済みの
                // 件数」であって、メールボックス全体の総件数ではない — 「今
                // 表示されてる件数」という要件そのものなので、これで正しい。
                HStack(spacing: OtegamiSpacing.xs) {
                    Text(selectionTitle)
                        .font(OtegamiFont.headline())
                        .foregroundStyle(OtegamiColor.ink)
                        .accessibilityIdentifier("mail.title")
                    if !environment.accounts.isEmpty {
                        Text("(\(currentThreadOrder.count))")
                            .font(OtegamiFont.caption())
                            .foregroundStyle(OtegamiColor.inkSecondary)
                            .accessibilityIdentifier("mail.title.count")
                    }
                }
            }
            ToolbarItemGroup(placement: .confirmationAction) {
                if showsGroupByAccountToggle {
                    groupByAccountToggleButton
                }
                unreadOnlyToggleButton
            }
        }
    }

    /// 実装ルール: 「再読込ボタンは不要 (pull-to-refresh で足りる)、その代わり
    /// 未読のみ表示のトグルをヘッダに」— アイコントグル (`AccountFilterChip`
    /// の選択状態と同じ「塗り＋文字色」で ON/OFF を色だけでなく形でも示す
    /// スタイル、CLAUDE.mdの「新しい色をその場で追加しない」に従い既存の
    /// パレット・チップトークンを再利用)。真偽値そのものは`isUnreadOnly`
    /// (`ListDisplaySettingsStore.unreadOnlyKey`の`@AppStorage`) — 実際の
    /// 絞り込みは`MessageListView.observeThreads()`側で行われる。
    private var unreadOnlyToggleButton: some View {
        Button {
            isUnreadOnly.toggle()
        } label: {
            Label("未読のみ表示", systemImage: isUnreadOnly ? "envelope.badge.fill" : "envelope.badge")
                .labelStyle(.iconOnly)
                .font(OtegamiFont.body())
                .foregroundStyle(isUnreadOnly ? OtegamiColor.accentText : OtegamiColor.inkSecondary)
                .padding(OtegamiSpacing.xs)
                .background(isUnreadOnly ? OtegamiColor.paleBaseStrong : Color.clear, in: Circle())
        }
        // `.buttonStyle(.plain)`必須: これが無いと iOS 26 系の Liquid Glass
        // ツールバーボタンが自前のティント丸背景をこのラベルの上に被せて
        // しまい、ON/OFF で変えているはずの塗り・文字色 (上の `.background`/
        // `.foregroundStyle`) が画面上まったく見分けられなくなる — 実機
        // シミュレータのスクリーンショットで実際に確認して気づいた
        // (`floatingSearchButton`が同じ`.buttonStyle(.plain)`で正しく
        // 自前スタイルのまま描画されているのとの比較で判明)。
        .buttonStyle(.plain)
        .accessibilityIdentifier("mail.unreadOnlyToggle")
        .accessibilityAddTraits(isUnreadOnly ? .isSelected : [])
    }

    /// Task #77 (ユーザー要望「アカウントごとにグルーピングする設定」):
    /// `unreadOnlyToggleButton`と同じ「塗り＋アイコン切り替え」スタイルの
    /// アイコントグル — ON/OFF は`isGroupByAccount`
    /// (`ListDisplaySettingsStore.groupByAccountKey`の`@AppStorage`) そのもの、
    /// 実際のセクション分割は`MessageListView`側。ON時のアイコンは
    /// `person.2.fill`(アカウントの集合という意味)、OFFは`rectangle.grid.1x2`
    /// (フラットな一覧という意味) — どちらも既存パレット/チップトークンを
    /// 再利用するだけで新しい色は足さない (`CLAUDE.md`)。
    private var groupByAccountToggleButton: some View {
        Button {
            isGroupByAccount.toggle()
        } label: {
            Label("アカウントでグループ化", systemImage: isGroupByAccount ? "person.2.fill" : "rectangle.grid.1x2")
                .labelStyle(.iconOnly)
                .font(OtegamiFont.body())
                .foregroundStyle(isGroupByAccount ? OtegamiColor.accentText : OtegamiColor.inkSecondary)
                .padding(OtegamiSpacing.xs)
                .background(isGroupByAccount ? OtegamiColor.paleBaseStrong : Color.clear, in: Circle())
        }
        // `unreadOnlyToggleButton`と同じ理由で`.buttonStyle(.plain)`必須
        // (Liquid Glass ツールバーボタンの既定ティント丸背景がON/OFFの
        // 塗り分けを潰してしまう — そのdoc comment参照)。
        .buttonStyle(.plain)
        .accessibilityIdentifier("mail.groupByAccountToggle")
        .accessibilityAddTraits(isGroupByAccount ? .isSelected : [])
    }

    /// 一覧画面左下のフローティング検索ボタン — `FolderListSheet
    /// .floatingSettingsButton`と同じ「丸い面＋影」の流儀をそのまま踏襲
    /// (実装ルール: 既存の左下フローティングボタンの実装例を踏襲)。
    /// accessibility identifier はヘッダにあった頃の`mail.searchButton`を
    /// 据え置き — `SearchUITestHelpers.openSearchScreen(in:)`はこの識別子
    /// だけを見ているため、位置が変わってもそのまま動く。
    ///
    /// Task #78 (ユーザー要望「アクセントブルーにするのは compose だけ
    /// じゃなくて設定とか検索とか翻訳要約のフローティングも」):
    /// `floatingComposeButton`だけがアクセント塗りだった状態を解消し、
    /// このボタンも`otegamiFloatingButtonChrome()`(既定`.neutral`トーン、
    /// `OtegamiFloatingButton.swift`) 経由でcomposeと同じアクセント塗り+
    /// 白アイコンへ統一した。
    private var floatingSearchButton: some View {
        Button {
            openSearch()
        } label: {
            Label("検索", systemImage: "magnifyingglass")
                .labelStyle(.iconOnly)
                .otegamiFloatingButtonChrome()
        }
        .buttonStyle(.plain)
        .padding(.leading, OtegamiSpacing.lg)
        .padding(.bottom, OtegamiSpacing.lg)
        .accessibilityIdentifier("mail.searchButton")
    }

    /// 一覧画面右下のフローティング作成ボタン — ヘッダの新規作成ボタン
    /// (`ToolbarItemGroup(placement: .confirmationAction)`) をここへ移設
    /// (ユーザー要望:「メールの新規作成ボタンは、ヘッダ部ではなく右下に
    /// フローティングして欲しい」)。左下の`floatingSearchButton`と対にな
    /// る配置・同じ「丸い面＋影」の流儀を踏襲する。accessibility
    /// identifier はヘッダにあった頃の`mail.composeButton`を据え置き —
    /// 参照 UITest がある場合でもこの識別子で動くようにするため。
    ///
    /// ユーザー要望「フローティングボタンの色は、sparkに合わせて」
    /// (参考画像: Spark の新規作成 FAB はアクセントブルーの塗りつぶし円＋
    /// 白いペンアイコン) — 当初は`floatingComposeButton`だけの変更
    /// だったが (`docs/design-system.md`のTask #77節)、Task #78で
    /// 全フローティングボタンに拡張された。見た目自体は
    /// `otegamiFloatingButtonChrome()`(`OtegamiFloatingButton.swift`)に
    /// 委譲 — このボタンだけの`.disabled(environment.accounts.isEmpty)`
    /// はそのまま残す。
    private var floatingComposeButton: some View {
        Button(action: onCompose) {
            Label("作成", systemImage: "square.and.pencil")
                .labelStyle(.iconOnly)
                .otegamiFloatingButtonChrome()
        }
        .buttonStyle(.plain)
        .padding(.trailing, OtegamiSpacing.lg)
        .padding(.bottom, OtegamiSpacing.lg)
        .accessibilityIdentifier("mail.composeButton")
        .disabled(environment.accounts.isEmpty)
    }

    /// 新画面構成 (1): 旧「ナビタイトルのタップでフォルダシートを開く」動線の
    /// 置き換え — 左上のハンバーガーアイコンが常にフォルダ／設定メニューを
    /// 開閉する。
    private var hamburgerButton: some View {
        Button {
            isMenuOpen.toggle()
        } label: {
            Label("メニュー", systemImage: "line.3.horizontal")
        }
        .accessibilityIdentifier("mail.hamburgerButton")
    }

    private var menuContent: some View {
        FolderListSheet(
            selectedMailboxId: selectedMailboxId,
            isUnifiedInboxSelected: isUnifiedInboxSelected,
            selectedUnifiedRole: selectedUnifiedRole,
            onSelectUnified: selectUnifiedInbox,
            onSelectMailbox: selectMailbox,
            onSelectUnifiedRole: selectUnifiedRole,
            onOpenOutbox: { presentAfterClosingMenu { showingOutbox = true } },
            onOpenDrafts: { presentAfterClosingMenu { showingDrafts = true } },
            onOpenFailedOps: { presentAfterClosingMenu { showingFailedOps = true } },
            onOpenMailboxSyncFailures: { presentAfterClosingMenu { showingMailboxSyncFailures = true } },
            onAddAccount: { presentAfterClosingMenu { accountEntryRoute = .typeSelection } },
            onOpenSettings: { presentAfterClosingMenu { showingSettings = true } },
            isMenuOpen: isMenuOpen,
            onClose: { isMenuOpen = false }
        )
    }

    private var selectedMailboxId: Int64? {
        guard case .mailbox(let mailboxSelection) = mailSelection else { return nil }
        return mailboxSelection.mailboxId
    }

    /// 画面構造改修バッチ (Task #33, 3): `FolderListSheet`の「横断ビュー」行の
    /// ハイライト用 — `selectedMailboxId`の`.unifiedRole`版。
    private var selectedUnifiedRole: MailboxRoleRecord? {
        guard case .unifiedRole(let role) = mailSelection else { return nil }
        return role
    }

    private func selectUnifiedInbox() {
        mailSelection = .unifiedInbox
        selectionTitle = String(localized: "すべての受信")
        accountFilter = nil
        isMenuOpen = false
    }

    private func selectMailbox(_ mailboxSelection: MailboxSelection, _ displayName: String) {
        mailSelection = .mailbox(mailboxSelection)
        selectionTitle = displayName
        accountFilter = nil
        isMenuOpen = false
    }

    /// 画面構造改修バッチ (Task #33, 3): カテゴリ優先メニューの「横断ビュー」行
    /// (例:「すべてのアーカイブ」) — `selectUnifiedInbox()`のrole一般化版。
    /// `accountFilter`は`.unifiedInbox`専用の1a絞り込みチップ用状態なので、
    /// ここでも念のため`nil`にリセットしておく (`.unifiedRole`selectionでは
    /// そもそも`AccountFilterChipRow`自体を出さないので実質無害だが、
    /// `selectMailbox`/`selectUnifiedInbox`と同じ後始末を揃えておく)。
    private func selectUnifiedRole(_ role: MailboxRoleRecord) {
        mailSelection = .unifiedRole(role)
        selectionTitle = String(localized: "すべての\(role.categoryDisplayName)")
        accountFilter = nil
        isMenuOpen = false
    }

    private func presentAddAccount() {
        accountEntryRoute = .typeSelection
    }

    /// G「削除・アーカイブ時の挙動」— `ThreadDetailView.onThreadRemoved`'s
    /// target: resolves the configured setting against `currentThreadOrder`
    /// and either replaces the pushed thread in place (`.navigationDestination
    /// (item:)` re-renders with the new id, no pop/push animation) or pops
    /// back to the list (`nil`).
    private func handleThreadRemoved(_ threadId: Int64) {
        let action = PostDeleteArchiveAction(rawValue: postDeleteArchiveActionRaw) ?? MessagePostActionSettingsStore.defaultAfterDeleteArchive
        selectedThreadId = MessagePostActionSettingsStore.nextThreadId(after: threadId, in: currentThreadOrder, action: action)
        // 実機フィードバック第3弾 (A): see `RootView.handleThreadRemoved(_:)`'s
        // identical doc comment — every arrival here is already a
        // grouped-mode dismissal, reset defensively anyway.
        selectedMessageId = nil
    }

    private func openSearch(presetQuery: String? = nil) {
        searchPresetQuery = presetQuery
        showingSearch = true
    }

    /// "送信を取り消す" tapped on `SendCountdownBar`: undoes the durable local
    /// write and reopens the Composer with the exact same fields — see
    /// `PendingSendCoordinator.cancelPendingSend()`'s doc comment. `nil`
    /// (nothing pending after all, e.g. a race with the countdown finalizing
    /// right as the tap landed) is a silent no-op; the bar disappearing on
    /// its own the moment `pendingSend` goes `nil` is feedback enough.
    private func handleCancelPendingSend() {
        Task {
            guard let snapshot = await environment.pendingSendCoordinator.cancelPendingSend() else { return }
            onOpenCancelledSend(snapshot)
        }
    }

    /// `FolderListSheet`'s rows all present *another* sheet — since the
    /// menu itself is now a drawer (not a `.sheet`), there's no "sheet from
    /// a sheet" nesting problem here (`HamburgerMenuContainer`'s doc
    /// comment), so this just closes the drawer and flips the target flag
    /// in the same call, rather than the old `pendingPostFolderAction` +
    /// `onDismiss` indirection design-phase-2's `.sheet`-based folder list
    /// needed.
    private func presentAfterClosingMenu(_ present: () -> Void) {
        isMenuOpen = false
        present()
    }
}
