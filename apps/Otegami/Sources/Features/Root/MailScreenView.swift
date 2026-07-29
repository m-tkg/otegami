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
    /// Task #105 続報 (実機ログで確定した cold launch 初回タップのバグ):
    /// 以前はここが `selectedThreadId`/`selectedMessageId` の**2つ**の
    /// `@State` で、`.navigationDestination(item: $selectedThreadId)` の
    /// destination クロージャが兄弟 state の `selectedMessageId` を読んで
    /// いた。SwiftUI はこの destination クロージャを登録時点の view 値で
    /// キャプチャすることがあり、cold launch 後の**初回 push に限って**
    /// 「`handleThreadSelected` は `singleMessageId=9879` を書いたのに
    /// `ThreadEntryView` には `preselectedMessageId=nil` が渡る」ことを
    /// 実機の OSLog で観測した (書き込み順を messageId 先行に変えても
    /// 再現)。アプリスイッチャーを出すと再描画でクロージャが最新値に
    /// 更新され「直る」ように見える、という報告挙動もこれで説明がつく。
    /// 対策: navigation item 自体に threadId + messageId を両方持たせ、
    /// destination クロージャは **item 引数だけ**から画面を組み立てる —
    /// 兄弟 state を読まないので stale capture が構造的に起きない。
    @State private var selectedRoute: ThreadRoute?
    /// `MessageListView` は互換のため従来どおり「messageId → threadId」の
    /// 順で2つの binding に書く — messageId の書き込みをここに一時保持し、
    /// threadId の書き込み時に `ThreadRoute` へ合成する (下の
    /// `selectedThreadIdBinding`/`selectedMessageIdBinding` 参照)。
    @State private var pendingTapMessageId: Int64?
    @State private var isSelecting = false
    /// G「削除・アーカイブ時の挙動」— see `MessageListView.onSummariesChanged`'s
    /// doc comment: the most recently observed on-screen thread order,
    /// refreshed on every `MessageListView` re-render, consulted by
    /// `handleThreadRemoved(_:)` to resolve "next message" navigation.
    /// Task #74 でも二つ目の消費者として使う: `.count`をタイトル横の件数表示
    /// (`toolbarContent`) にそのまま流用する — 新規の観測を増やさずに済む
    /// (詳細はその使用箇所のdoc comment参照)。
    @State private var currentThreadOrder: [Int64] = []
    /// Task #108: see `MessageListView.suppressInternalUndoToast`'s doc
    /// comment — the undo toast's actual rendering lives here (in an
    /// `.overlay` applied *after* the floating search/compose buttons
    /// below) instead of inside `MessageListView` itself, so it's
    /// guaranteed to paint on top of those buttons rather than being
    /// silently layered underneath them by the outer `.overlay` chain.
    @State private var pendingUndoPayload: MessageListView.UndoToastPayload?
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

    /// Task #77 (ユーザー要望「アカウントごとにグルーピングする設定」): 元は
    /// 未読のみトグルの隣に置いた「アカウントでグループ化」ヘッダボタンの
    /// 状態だった。
    ///
    /// Task #92 (アカウントダイジェスト画面) でボタンは`AccountDigestView`
    /// (アカウントごとの件数+直近プレビューを一段挟んで見せる画面)への
    /// **プッシュ遷移**トリガーに変わり、Task #99 で永続`@AppStorage`トグル
    /// (`unreadOnlyToggleButton`/`isUnreadOnly`と同じ「タップでon/off反転」)
    /// に戻った。
    ///
    /// **Task #106**: ヘッダのボタン自体を廃止し、1a の「すべて」チップ
    /// (`AccountFilterChipRow.AllModeFilterChip`) のプルダウン (時系列 /
    /// アカウント別) に統合した — この`@AppStorage`のキー自体・値の意味
    /// (ON=アカウント別ダイジェスト表示) は変えていないので、チップ側の
    /// 選択がそのままここに反映される (`isUnreadOnly`と同じ「別ビューの同じ
    /// キーへの`@AppStorage`が両方に伝わる」設計)。実際にダイジェスト表示に
    /// するかどうかは`isShowingAccountDigest`(`content`の分岐条件) が
    /// `isAccountDigestEligible`との整合も含めて決める — 例えば単一メール
    /// ボックス選択中はこの値が`true`のままでもダイジェストは出ない。
    /// `MessageListView`はこのキーを一切読まない
    /// (`MessageListView.listContent`のdoc comment参照)。
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
                selectedRoute = ThreadRoute(threadId: threadId, messageId: nil)
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
            // 検索画面再構成 (Task #86): 同じ「タップ不要の直接遷移」パターン
            // で`SearchScreenView`を`scripts/verify-screen.sh`から開けるように
            // する — トップバー/タブ/保存済み検索の見た目確認用。
            // `OTEGAMI_UITEST_SEARCH_PRESET_QUERY`(任意)を指定すると、既存の
            // `presetQuery`経路 (`ThreadDetailView`の「検索」ツールバーボタン
            // と同じ仕組み) でクエリ入力済みの「結果表示中」状態も、タップ
            // 無しで直接screenshotできる。
            if ProcessInfo.processInfo.arguments.contains("-uitestsOpenSearchDirectly") {
                if let preset = ProcessInfo.processInfo.environment["OTEGAMI_UITEST_SEARCH_PRESET_QUERY"], !preset.isEmpty {
                    searchPresetQuery = preset
                }
                showingSearch = true
            }
            // Task #92 (アカウントダイジェスト画面)、Task #99 でトグル化:
            // 同じ「タップ不要の直接遷移」パターンで`isGroupByAccount`を
            // `true`にし、`scripts/verify-screen.sh`からグルーピングボタン
            // をタップせずにダイジェスト表示 (`isShowingAccountDigest`) の
            // 見た目を直接screenshotできるようにする。
            if ProcessInfo.processInfo.arguments.contains("-uitestsOpenAccountDigestDirectly") {
                isGroupByAccount = true
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
                .navigationDestination(item: $selectedRoute) { route in
                    // Task #105 続報: `route` (item 引数) だけから組み立てる —
                    // 兄弟 state を読まない (上の `selectedRoute` doc comment)。
                    ThreadEntryView(
                        threadId: route.threadId, preselectedMessageId: route.messageId, onReply: onReply, onForward: onForward,
                        onSearchFromSender: { query in openSearch(presetQuery: query) },
                        onThreadRemoved: handleThreadRemoved
                    )
                }
                // Task #124 実機フィードバック「送信キャンセルのカウントダウン
                // バーが表示されないことがある」: `SendCountdownBar` lives in
                // `content` — this stack's *root* — so replying from an
                // already-pushed thread (a very common flow) leaves it
                // completely occluded behind that pushed `ThreadEntryView`;
                // the countdown still runs (nothing was actually lost), it
                // was just never visible, and with it "送信を取り消す" was
                // never reachable either. Popping back to the root the
                // instant a new send starts counting down fixes both.
                .onChange(of: environment.pendingSendCoordinator.pendingSend?.id) { _, newValue in
                    guard newValue != nil else { return }
                    selectedRoute = nil
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
                if let selectedRoute {
                    ThreadEntryView(
                        threadId: selectedRoute.threadId, preselectedMessageId: selectedRoute.messageId, onReply: onReply, onForward: onForward,
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
            if environment.accounts.isEmpty {
                emptyState
            } else if isShowingAccountDigest {
                // Task #99: プッシュ遷移をやめ、一覧領域の中身だけをこの
                // 埋め込み`AccountDigestView`に差し替える — ヘッダ
                // (`toolbarContent`) やフローティングボタンはこの`content`
                // の外側/overlayのままなので変わらず表示され続ける。
                //
                // Task #106 実機フィードバック: チップ行はダイジェスト表示中も
                // 常時出す — 「すべて ▸ アカウント別」に切り替えた瞬間に
                // チップ行ごと消えると「時系列」へ戻す手段が無くなるため。
                if isUnifiedInboxSelected {
                    AccountFilterChipRow(accounts: environment.accounts, selectedAccountId: $accountFilter)
                }
                AccountDigestView(role: digestRole, onSelectAccount: selectDigestAccount)
            } else {
                if isUnifiedInboxSelected {
                    AccountFilterChipRow(accounts: environment.accounts, selectedAccountId: $accountFilter)
                }
                MessageListView(
                    selection: mailSelection,
                    unifiedInboxAccountFilter: accountFilter,
                    selectedThreadId: selectedThreadIdBinding,
                    selectedMessageId: selectedMessageIdBinding,
                    onSelectionModeChanged: { isSelecting = $0 },
                    onSummariesChanged: { currentThreadOrder = $0 },
                    suppressInternalUndoToast: true,
                    onPendingUndoChanged: { pendingUndoPayload = $0 }
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
        // Task #108 (実機報告「元に戻すトーストが検索・新規作成 FAB の
        // 背面に描画され重なる」): このoverlayは上の2つ (floatingSearch
        // Button/floatingComposeButton)より**後**に付けている — SwiftUI の
        // `.overlay`チェーンは後から適用したものほど手前に描画されるため、
        // ここに置くだけでFABより確実に手前になる (`.zIndex`はチェーンが
        // 生成する各`ZStack`の中でしか効かず、この階層をまたいでは効かない
        // ため、根本修正はこの「最後に付ける」という位置そのもの — 明示
        // `.zIndex`は下記の通り保険として併記)。縦位置もFABの上端
        // (フローティングボタンの直径+底からの余白) を確実に超える位置まで
        // 持ち上げ、重なり自体を無くす (`MessageListView`が以前担っていた
        // クリアランス計算をここに集約した — `pendingUndoPayload`のdoc
        // comment参照)。
        .overlay(alignment: .bottom) {
            if let pendingUndoPayload {
                UndoToast(message: pendingUndoPayload.message, onUndo: pendingUndoPayload.onUndo)
                    .animation(.default, value: pendingUndoPayload.message)
                    #if os(iOS)
                    .padding(.bottom, floatingButtonClearance)
                    #endif
                    .zIndex(1)
            }
        }
    }

    /// Task #108: FAB (`floatingSearchButton`/`floatingComposeButton`、
    /// `OtegamiFloatingButtonChromeModifier`) の円の直径 + その`overlay`
    /// 自身の`.padding(.bottom, OtegamiSpacing.lg)`を、既存のトークンの
    /// 組み合わせだけで再現した値 — マジックナンバーを新設しない
    /// (`MessageListView`の旧実装のコメントと同じ方針)。円の直径は
    /// `OtegamiFloatingButtonChromeModifier`の`frame`(`.xl + .xs`)と
    /// `padding`(`.md + .xs`を両側)の合計、そこにボタン自身の下端余白
    /// (`.lg`)と、トーストとの間に一呼吸ぶんの余白 (`.sm`)を足す。
    private var floatingButtonClearance: CGFloat {
        let circleDiameter = (OtegamiSpacing.xl + OtegamiSpacing.xs) + 2 * (OtegamiSpacing.md + OtegamiSpacing.xs)
        return circleDiameter + OtegamiSpacing.lg + OtegamiSpacing.sm
    }

    /// Task #99: 一覧領域をダイジェスト表示に切り替えるかどうか —
    /// `isGroupByAccount`(永続トグル)だけでなく`isAccountDigestEligible`
    /// と同じ「ダイジェストが意味を持つ画面か」の条件も満たす必要がある
    /// (単一メールボックス選択中や、既にアカウント絞り込みチップ/ダイジェスト
    /// 行タップで1アカウントに絞られている間はダイジェストではなく通常の
    /// 一覧を出す)。行タップ (`selectDigestAccount`) は`accountFilter`を
    /// セットするだけで`isGroupByAccount`自体は変えない — その結果この
    /// 条件が`false`になって通常の絞り込み一覧に切り替わり、絞り込みチップ
    /// (`AccountFilterChipRow`)の「すべて」でその絞り込みを解除すると
    /// `accountFilter`が`nil`に戻ってこの条件が再び`true`になり、ダイジェスト
    /// 表示へ自動的に戻る(仕様「絞り込み一覧から戻ったらダイジェスト表示に
    /// 戻ること」)。
    private var isShowingAccountDigest: Bool {
        isGroupByAccount && isAccountDigestEligible
    }

    /// Task #92: `AccountDigestView`に渡す`role` — `mailSelection`が
    /// `.unifiedInbox`なら`.inbox`、`.unifiedRole(let role)`ならその
    /// `role`そのもの。`.mailbox`選択中はそもそも`isAccountDigestEligible`
    /// が`false`で`isShowingAccountDigest`自体が成立しない (Task #106
    /// 以降、ダイジェストへの入口である「すべて」チップ (`AccountFilterChipRow
    /// .AllModeFilterChip`) 自体、`.unifiedInbox`選択中にしか表示されない)
    /// ため、`.mailbox`のフォールバック値 (`.inbox`)が実際に使われることは
    /// ない。
    private var digestRole: MailboxRoleRecord {
        switch mailSelection {
        case .unifiedInbox: .inbox
        case .unifiedRole(let role): role
        case .mailbox: .inbox
        }
    }

    /// `AccountDigestView`の行タップ — 1a のアカウント絞り込みチップと
    /// 同じ`accountFilter`にセットして`MessageListView`をそのアカウントに
    /// 絞り込む(`.unifiedRole`にも`MessageListView.observeThreads()`が
    /// Task #92 で`unifiedInboxAccountFilter`を適用するようになったので、
    /// `mailSelection`がどちらのケースでも同じ1行で絞り込みが効く)。
    ///
    /// Task #99: `isGroupByAccount`はここでは**変えない** — トグルは永続
    /// 設定に戻したので、行タップだけでOFFに戻すのは意図的な仕様変更
    /// (プッシュ遷移の「戻る」相当の動作) を暗黙に混ぜ込むことになり
    /// 望ましくない。`accountFilter`がセットされたことで`isShowingAccountDigest`
    /// が`false`になり、絞り込み一覧に自動的に切り替わる。
    private func selectDigestAccount(_ accountId: String) {
        accountFilter = accountId
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

    /// Task #77: 「アカウントでグループ化」ボタン自体を出すかどうか —
    /// `MessageListView.showsAccountAccent`と同じ条件をこの画面側の状態
    /// (`mailSelection`/`accountFilter`) から再現する。単一メールボックス
    /// 選択中 (`.mailbox`) や、1a のアカウント絞り込みチップで1アカウントに
    /// 絞った統合受信トレイ、アカウントが1つしか無い場合は、ダイジェスト
    /// (Task #92) を開いても全行が同じアカウントで意味が無いのでボタン
    /// 自体を隠す(ユーザー要望「単一アカウントのメールボックス表示時は
    /// トグルを出さない」)。
    ///
    /// Task #92: `.unifiedRole`も`.unifiedInbox`と同じく`accountFilter`
    /// (ダイジェスト画面の行タップ経由でのみセットされる)で絞り込み済みなら
    /// 隠す — `MessageListView.isMultiAccountScope`を同じ理由で揃えたのと
    /// 対になる変更(そちらのdoc comment参照)。
    ///
    /// Task #99: この`Bool`は元々ヘッダボタンの表示可否と`isShowingAccountDigest`
    /// の両方を兼ねていた — ボタンを隠す条件と実際にダイジェストを出す
    /// 条件を1つの計算プロパティに保つことで、ボタンが見えないのに
    /// ダイジェストだけ出続けるような食い違いを防ぐ意図。
    ///
    /// **Task #106**: ヘッダボタン自体は廃止した (「すべて」チップの
    /// プルダウンに統合) が、この計算プロパティは`isShowingAccountDigest`
    /// の条件としてそのまま生き残っている — 名前をその実態
    /// (`isAccountDigestEligible`) に合わせて変えただけで、判定内容
    /// (`.mailbox`選択中／単一アカウント絞り込み中／アカウント1つのみ、
    /// では`false`) は変えていない。
    private var isAccountDigestEligible: Bool {
        switch mailSelection {
        case .unifiedInbox, .unifiedRole:
            guard accountFilter == nil else { return false }
        case .mailbox:
            return false
        }
        return environment.accounts.count > 1
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !isSelecting {
            ToolbarItem(placement: hamburgerButtonPlacement) {
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
                // Task #106: 「アカウントでグループ化」ボタンはここから廃止
                // — 1a の「すべて」チップのプルダウン (`AccountFilterChipRow
                // .AllModeFilterChip`) に統合した。
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

    /// Task #109 (実機報告「メール本文から一覧に pop で戻ると、左上の
    /// ハンバーガーボタンが右側のトグルカプセル (`unreadOnlyToggleButton`
    /// 等) に混ざって表示される」): 元は`.navigation`だった —
    /// `ToolbarItemPlacement.navigation`はAppleのドキュメント上も「ナビ
    /// ゲーション関連のアクションを表す」抽象的な意味論で、iOSの実レイアウト
    /// 上どのグループに落ちるかが`.principal`/`.confirmationAction`の
    /// 組み合わせやNavigationStackのpush/pop後の再合成タイミングによって
    /// 不安定になりうる (この症状はまさにpop直後の再配置で発生)。iOS/iPadOS
    /// 専用の`.topBarLeading`は左端に固定される明確な意味論を持つため、
    /// これに固定して安定させる — `MailScreenView`はmacOSでもコンパイル
    /// される (doc comment参照、実際にはinstantiateされない) ため、
    /// `.topBarLeading`が存在しないmacOS向けには`.navigation`のまま残す。
    private var hamburgerButtonPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
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
        // 実機フィードバック第3弾 (A): messageId は付けない — every arrival
        // here is already a grouped-mode dismissal (see `RootView
        // .handleThreadRemoved(_:)`'s identical doc comment)。
        selectedRoute = MessagePostActionSettingsStore.nextThreadId(after: threadId, in: currentThreadOrder, action: action)
            .map { ThreadRoute(threadId: $0, messageId: nil) }
        pendingTapMessageId = nil
    }

    /// Task #105 続報: `MessageListView` の2本の binding を `selectedRoute`
    /// へ合成するアダプタ。書き込み順 (messageId → threadId) は
    /// `MessageListView.handleThreadSelected` が保証している。
    private var selectedThreadIdBinding: Binding<Int64?> {
        Binding(
            get: { selectedRoute?.threadId },
            set: { newValue in
                if let newValue {
                    selectedRoute = ThreadRoute(threadId: newValue, messageId: pendingTapMessageId)
                } else {
                    selectedRoute = nil
                }
                pendingTapMessageId = nil
            }
        )
    }

    private var selectedMessageIdBinding: Binding<Int64?> {
        Binding(
            get: { selectedRoute?.messageId },
            set: { pendingTapMessageId = $0 }
        )
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

/// Task #105 続報: 「開くスレッド + フラット時に開く単一メッセージ」を
/// 1つの navigation item に束ねた値。`MailScreenView.selectedRoute` の
/// doc comment 参照 — destination クロージャが兄弟 state を読むと cold
/// launch の初回 push で stale capture が起きるため、必要な値はすべて
/// item 自身が運ぶ。`id` は threadId — `handleThreadRemoved` の「次の
/// スレッドへ差し替え」で id が変わり、`.navigationDestination(item:)` が
/// pop せず in-place で再描画する既存挙動を維持する。
private struct ThreadRoute: Hashable, Identifiable {
    let threadId: Int64
    let messageId: Int64?
    var id: Int64 { threadId }
}
