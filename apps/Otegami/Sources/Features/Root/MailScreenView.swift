import SwiftUI
import OtegamiStore

/// iOS's sole always-visible screen (新画面構成 (1)): a plain title (「すべての
/// 受信」等 — no longer tappable, see below) → `AccountFilterChipRow` (only
/// meaningful while the unified inbox is selected) → `MessageListView`.
/// `FolderListSheet`'s folder-navigation content (統合受信トレイ／アカウント別
/// ツリー／下書き等／設定) presents as a standard full-height `.sheet`
/// (Liquid Glass Phase 3, 2026-08-07、`docs/design-system.md`「Liquid Glass
/// 方針」節) — the custom leading-edge drawer (`HamburgerMenuContainer`) it
/// used before this phase is gone, so system Liquid Glass sheet chrome
/// (角丸・背景・ドラッグインジケータ) applies automatically.
/// Owns the one piece of navigation state `MessageListView` itself no
/// longer does on iOS (`navigationTitle`/`.searchable` moved out — see that
/// view's doc comment): which mailbox is selected, which account the filter
/// chips narrow to, and which thread (if any) is pushed.
///
/// 旧「ナビタイトルのタップでフォルダシートを開く」動線はハンバーガーボタンに
/// 置き換えた (`CLAUDE.md`) — タイトル自体は素の `Text` に戻り、フォルダ切替は
/// 常に左上のハンバーガーアイコンから。検索・新規作成は一覧画面右下の
/// speed-dial FAB (`SpeedDialFAB`、Task #131 — 「…」1個をタップすると
/// その上に「新規作成」「検索」が縦に展開する) から呼ぶ — ヘッダの再読込
/// ボタンは廃止 (pull-to-refresh に一本化、`MessageListView`側) し、空いた
/// ヘッダには「未読のみ表示」トグル (`unreadOnlyToggleButton`) を追加した。
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
    var onReply: (Int64, Bool) -> Void
    /// 新画面構成 (3): メール本文画面フッターツールバーの「転送」。
    var onForward: (Int64) -> Void
    /// C7: reopens the Composer with a just-cancelled pending send's fields
    /// — see `handleCancelPendingSend()`.
    var onOpenCancelledSend: (PendingSendDraftSnapshot) -> Void

    @State private var mailSelection: SidebarSelection = .unifiedInbox
    @State private var accountFilter: String?
    /// ユーザー要望 (2026-08-02「ヘッダの『すべての受信』を押すとハンバー
    /// ガーメニューのアカウントごとじゃない項目 (横断ビュー) をプルダウンで
    /// 選べるようにして欲しい」): ヘッダタイトルの`Menu`が並べる横断ビュー
    /// の一覧・順序 — `FolderListSheet`のカテゴリセクションと同じ並び順に
    /// 揃えるため、同じ`FolderCategoryOrderStore`をこの画面でも
    /// `@AppStorage`で直接監視する (`FolderListSheet.categoryOrder`の
    /// doc comment参照: `@AppStorage`は配列を直接扱えないので raw 文字列を
    /// 監視し、都度`loadOrder(from:)`でデコードする)。
    @AppStorage(FolderCategoryOrderStore.key) private var headerMenuCategoryOrderRaw = ""
    /// Task #131 (一覧FABのspeed-dial化): 右下の「…」FABが展開中かどうか —
    /// 展開状態は仕様どおり永続化しない (`@AppStorage`ではなくただの
    /// `@State`、アプリを再起動すれば常に畳んだ状態から始まる)。既定は
    /// `false`だが、`scripts/verify-screen.sh`が「展開状態のスクリーン
    /// ショット」をタップ無しで撮れるよう、`-uitestsExpandFabDirectly`
    /// (実機/通常起動では引数に無いので常にno-op) が付いていれば最初から
    /// `true`で始める — `FolderListSheet.resetCollapseStateToCurrentSelection()`
    /// の`-uitestsExpandFolderMenuSectionsDirectly`と同じ「タップ不要の
    /// 直接遷移」パターン。
    @State private var isFabExpanded = ProcessInfo.processInfo.arguments.contains("-uitestsExpandFabDirectly")
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
    /// 通知の本体タップで開く `PushNotificationOpenView` (ローディング→
    /// 本文/失敗) の navigation item — `selectedRoute` とは独立した destination
    /// にする (対象メールが未同期の時点では `threadId` が存在せず
    /// `ThreadRoute` を作れないため)。`applyPendingPushOpenTargetIfNeeded()`
    /// が設定し、compact では push、regular では右ペインの表示分岐が消費する。
    @State private var pushOpenRoute: PushOpenRoute?
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
    ///
    /// Task #74 は`.count`をタイトル横の件数表示 (`toolbarContent`) にも
    /// 流用していた ("今表示されてる件数" = ページングで切られた読み込み
    /// 済み行数) が、ユーザー指示 (2026-07-29) でその表示は
    /// `currentUnreadCount` (メッセージ単位・現在のボックススコープの
    /// 未読数、`MessageListView.onUnreadCountChanged`) に置き換えた —
    /// この`currentThreadOrder`自体はG「削除・アーカイブ時の挙動」用の
    /// 唯一の消費者に戻っている。
    @State private var currentThreadOrder: [Int64] = []
    /// Task #74 → ヘッダ件数表示のメッセージ単位未読数化 (ユーザー指示、
    /// 2026-07-29、#137 と同じバッチ): タイトル横の件数
    /// (`toolbarContent`)が実際に表示する値 — `MessageListView
    /// .onUnreadCountChanged`から流れてくる、現在の`mailSelection`
    /// (と`accountFilter`)スコープのメッセージ単位未読数。スレッド数でも
    /// 「今読み込み済みの行数」でもなく、スレッドを畳んでいても展開して
    /// いても (スレッド表示 ON/OFF どちらでも) 同じ定義 — 例えばスレッドが
    /// 4つでもその中の未読メッセージが6件あればここは6になる。
    @State private var currentUnreadCount = 0
    /// Task #108: see `MessageListView.suppressInternalUndoToast`'s doc
    /// comment — the undo toast's actual rendering lives here (in an
    /// `.overlay` applied *after* the floating search/compose buttons
    /// below) instead of inside `MessageListView` itself, so it's
    /// guaranteed to paint on top of those buttons rather than being
    /// silently layered underneath them by the outer `.overlay` chain.
    @State private var pendingUndoPayload: MessageListView.UndoToastPayload?
    @AppStorage(MessagePostActionSettingsStore.afterDeleteArchiveKey) private var postDeleteArchiveActionRaw = MessagePostActionSettingsStore.defaultAfterDeleteArchive.rawValue

    /// フォルダ／設定メニュー (`FolderListSheet`) の表示状態 — Liquid Glass
    /// Phase 3 (2026-08-07) でカスタムドロワー (`HamburgerMenuContainer`) を
    /// 廃止し標準`.sheet`提示に変更したのに合わせ、旧名`isMenuOpen`から他の
    /// `showingX`系シート状態 (`showingOutbox`等) と揃えて改名した。
    @State private var showingFolderMenu = false
    @State private var accountEntryRoute: AccountEntryRoute?
    @State private var showingOutbox = false
    @State private var showingDrafts = false
    @State private var showingFailedOps = false
    @State private var showingSettings = false
    /// Liquid Glass Phase 3: `FolderListSheet`の行 (送信待ち/下書き/同期
    /// エラー/アカウント追加/設定) がタップされてから、`showingFolderMenu`の
    /// `.sheet(onDismiss:)`が実際に次のシートを開くまで一時的に保持する
    /// クロージャ — `presentAfterClosingMenu(_:)`/`handleFolderMenuDismissed()`
    /// 参照。
    @State private var pendingPostFolderAction: (() -> Void)?

    /// Task #140 (実機報告「ツールバー検索の `from:` プリセットが不発になる
    /// ことがある」): 元は`showingSearch: Bool` + `searchPresetQuery:
    /// String?`という**2つの独立した`@State`**だった — `openSearch(presetQuery:)`
    /// がこの2つを同じ関数内で連続して書き込み (`searchPresetQuery = ...`
    /// の直後に`showingSearch = true`)、`.sheet(isPresented:)`はその
    /// トレーリングクロージャの中で兄弟`@State`(`searchPresetQuery`)を
    /// 直接読む形だった。`ThreadRoute`のdoc comment (このファイル下部)
    /// が同じ理由で警告している「destination クロージャが兄弟 state を
    /// 読むと stale capture が起きる」パターンそのもので、2回連続した
    /// `@State`書き込みが必ず同じ描画パスにまとまる保証はSwiftUI側には
    /// 無い — `isPresented`がfalse→trueへ遷移した*その瞬間*の
    /// `searchPresetQuery`がまだ古い値(前回のクエリ、または`onDismiss`で
    /// リセットされた`nil`)のままシートへ渡ることがあり、これが「毎回では
    /// なく時々`from:`が入らない」という実機報告の形と一致する。
    /// `SearchSheetRoute`(下記)に両方の値を1つの`Identifiable`へ束ね、
    /// `.sheet(item:)`で受け渡すことで、この種の競合を構造的に起こり
    /// 得なくした — `ThreadRoute`/`accountEntryRoute`と同じ設計。
    @State private var searchRoute: SearchSheetRoute?

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

    /// Task #142: 「未読のみ表示」の隣に並ぶ「フラグ付きのみ表示」トグル —

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
        mailContent
        // Task #56 — see `AppEnvironment.uitestDirectOpenThreadId`'s doc
        // comment. `.task` (not `.onAppear`) so this doesn't fight
        // `@Observable`'s own dispatch timing; runs once per this view's
        // lifetime, which is exactly "once per app launch" since this view
        // is never torn down and recreated while the app is running. A
        // no-op (`environment.uitestDirectOpenThreadId == nil`) on every
        // real launch.
        .task {
            // Task #142 撤去の後始末: トグル UI 削除前に ON へ倒していた
            // 端末が「ピン留めのみ」で固定される事故を防ぐため、起動時に
            // 保存値を必ず消す (UI が無い間は常に OFF 相当)。
            UserDefaults.standard.removeObject(forKey: ListDisplaySettingsStore.pinnedOnlyKey)
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
                showingFolderMenu = true
            }
            // 検索画面再構成 (Task #86): 同じ「タップ不要の直接遷移」パターン
            // で`SearchScreenView`を`scripts/verify-screen.sh`から開けるように
            // する — トップバー/タブ/保存済み検索の見た目確認用。
            // `OTEGAMI_UITEST_SEARCH_PRESET_QUERY`(任意)を指定すると、既存の
            // `presetQuery`経路 (`ThreadDetailView`の「検索」ツールバーボタン
            // と同じ仕組み) でクエリ入力済みの「結果表示中」状態も、タップ
            // 無しで直接screenshotできる。
            if ProcessInfo.processInfo.arguments.contains("-uitestsOpenSearchDirectly") {
                let preset = ProcessInfo.processInfo.environment["OTEGAMI_UITEST_SEARCH_PRESET_QUERY"]
                openSearch(presetQuery: (preset?.isEmpty ?? true) ? nil : preset)
            }
            // Task #92 (アカウントダイジェスト画面)、Task #99 でトグル化:
            // 同じ「タップ不要の直接遷移」パターンで`isGroupByAccount`を
            // `true`にし、`scripts/verify-screen.sh`からグルーピングボタン
            // をタップせずにダイジェスト表示 (`isShowingAccountDigest`) の
            // 見た目を直接screenshotできるようにする。
            if ProcessInfo.processInfo.arguments.contains("-uitestsOpenAccountDigestDirectly") {
                isGroupByAccount = true
            }
            // Task #141 実機フィードバック検証用 (`scripts/verify-screen.sh
            // list-all-mail`): 同じ「タップ不要の直接遷移」パターンで
            // 「すべてのメール」(`.unifiedRole(.all)`) をタップ無しで直接選択
            // し、ヘッダのタイトルが「すべてのすべてのメール」に二重化
            // していないこと (`selectUnifiedRole(_:)`のdoc comment参照) を
            // screenshotで確認できるようにする。
            if ProcessInfo.processInfo.arguments.contains("-uitestsSelectAllMailDirectly") {
                selectUnifiedRole(.all)
            }
            // 通知タップ→ローディング画面 (`PushNotificationOpenView`) の
            // 見た目確認用 — 同じ「タップ不要の直接遷移」パターン。存在
            // しない accountId を指すダミー request なので、解決は即座に
            // 失敗し loading → failed の両状態を screenshot できる
            // (実機/通常起動では引数に無いので常に no-op)。
            if ProcessInfo.processInfo.arguments.contains("-uitestsOpenPushLoadingDirectly") {
                pushOpenRoute = PushOpenRoute(accountId: "uitest-push-open-missing-account", uidNext: 2)
            }
            // 通知タップからの起動 (コールドスタート) を拾う — ウォーム
            // スタート側は下の `.onReceive` 参照。
            applyPendingPushOpenTargetIfNeeded()
        }
        // プッシュ通知の本体タップ (`AppDelegate.userNotificationCenter`)
        // をアプリ起動中に受けた場合はこの`.task`は二度と走らないため、
        // `PushNotificationOpenCoordinator.didUpdateNotification`購読で
        // 拾う — `PushNotificationOpenCoordinator`のdoc comment参照。
        .onReceive(NotificationCenter.default.publisher(for: PushNotificationOpenCoordinator.didUpdateNotification)) { _ in
            applyPendingPushOpenTargetIfNeeded()
        }
        .onChange(of: selectedRoute, handleSelectedRouteChanged)
    }

    /// `PushNotificationOpenCoordinator`に積まれた「通知タップで開くべき
    /// メール」(未解決の accountId/uidNext) を消費し、あれば`pushOpenRoute`
    /// へ反映して`PushNotificationOpenView`(ローディング画面)へ即遷移する —
    /// 対象の解決・優先同期はそのビューの中で行う。`.task`(コール
    /// ドスタート)と`.onReceive`(ウォームスタート)の両方から呼ばれる —
    /// どちらが先に走ってもどちらか一方で確実に消費される。
    private func applyPendingPushOpenTargetIfNeeded() {
        guard let request = PushNotificationOpenCoordinator.shared.consumePendingRequest() else { return }
        pushOpenRoute = PushOpenRoute(accountId: request.accountId, uidNext: request.uidNext)
    }

    /// `PushNotificationOpenView`内の`ThreadEntryView`から届く
    /// `onThreadRemoved` — 通知経由の画面をまず閉じてから、一覧経由と同じ
    /// `handleThreadRemoved`(「次のスレッドへ」設定の解決)へ委譲する。
    private func handlePushOpenThreadRemoved(_ threadId: Int64) {
        pushOpenRoute = nil
        handleThreadRemoved(threadId)
    }

    /// regular 幅で一覧から別スレッドをタップしたとき (`selectedRoute`が
    /// 非nilへ変化) は通知経由の`PushNotificationOpenView`を閉じ、右ペイン
    /// をタップしたスレッドへ譲る。compact では`PushNotificationOpenView`
    /// がpush済みで一覧に触れないため実質no-op。
    private func handleSelectedRouteChanged(_ oldValue: ThreadRoute?, _ newValue: ThreadRoute?) {
        guard newValue != nil else { return }
        pushOpenRoute = nil
    }

    /// Task #70: 中身が`compactNavigationStack`/`regularSplitView`のどちら
    /// であっても、共通の状態 (`accountEntryRoute`/`showingOutbox`等) が
    /// 駆動するシート群はここで一度だけ付ける (どちらの分岐でも同じ
    /// `.sheet`群が要る一方、分岐のたびに複製すると片方だけ直し忘れる
    /// 不整合の元になるため)。`.tint`もここに一本化 (以前は
    /// `mailNavigationStack`自身に付いていたのを、両分岐の共通祖先である
    /// この階層に上げただけ)。
    ///
    /// Liquid Glass Phase 3 (2026-08-07): フォルダ／設定メニュー
    /// (`FolderListSheet`、`showingFolderMenu`) も、カスタムドロワー
    /// (`HamburgerMenuContainer`) をやめてこの並びに標準`.sheet`として
    /// 加えた。`.large`固定 — フォルダ切替はナビゲーション頻度が高いため
    /// フルハイトを基本にする。`FolderListSheet`の各行 (送信待ち/下書き/
    /// 同期エラー/アカウント追加/設定) はこのシート自身からさらにもう1枚
    /// シートを重ねられない (このアプリで確認済みの「シートからシートを
    /// 開く」壊れ方 — `ComposerView.swift`の同じ既知不調のコメント参照)
    /// ため、各行は`onOpen*`クロージャで`presentAfterClosingMenu(_:)`を
    /// 呼ぶだけに留め、実際の次のシート提示は`onDismiss`
    /// (`handleFolderMenuDismissed`) がこのシートの dismiss アニメーション
    /// 完了後に行う — design-phase-2 で一度採用されていた
    /// `pendingPostFolderAction` + `onDismiss`の構図を、ドロワー化で
    /// 一時的に不要になっていたところへ再び戻した形。
    private var mailContent: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularSplitView
            } else {
                compactNavigationStack
            }
        }
        .tint(OtegamiColor.accent)
        .sheet(isPresented: $showingFolderMenu, onDismiss: handleFolderMenuDismissed) {
            menuContent
                .presentationDetents([.large])
        }
        .sheet(item: $accountEntryRoute) { route in
            accountEntryDestination(for: route, binding: $accountEntryRoute)
        }
        .sheet(isPresented: $showingOutbox) { OutboxView() }
        .sheet(isPresented: $showingDrafts) {
            DraftsView(onOpenDraft: onOpenDraft, onOpenServerDraft: onOpenServerDraft)
        }
        .sheet(isPresented: $showingFailedOps) { FailedOperationsView() }
        .sheet(isPresented: $showingSettings) { SettingsSheetView() }
        .sheet(item: $searchRoute) { route in
            SearchScreenView(onReply: onReply, presetQuery: route.presetQuery)
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
                // 通知の本体タップ (`pushOpenRoute`) — `selectedRoute`とは別の
                // destination として push する (`pushOpenRoute`のdoc comment)。
                .navigationDestination(item: $pushOpenRoute) { route in
                    // `.id(route)`: push済みのまま別の通知をタップした場合
                    // (item差し替えのin-place再描画) に、前のメールの解決
                    // 済み`phase`(`@State`)を持ち越さず作り直すため。
                    PushNotificationOpenView(
                        accountId: route.accountId, uidNext: route.uidNext, onReply: onReply, onForward: onForward,
                        onSearchFromSender: { query in openSearch(presetQuery: query) },
                        onThreadRemoved: handlePushOpenThreadRemoved
                    )
                    .id(route)
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
    /// せず、`compactNavigationStack`と同じ`showingFolderMenu`の`.sheet`
    /// (`mailContent`参照) をそのまま流用する (`docs/design-system.md`の
    /// Task #70節に判断を記録) — ハンバーガーボタン (`listColumn`の
    /// `toolbarContent`内) を押せば2ペインの上に同じシートが重なる。
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

    /// 右ペイン — Task #70要件3「スレッド本文はこの右ペイン内で完結する」:
    /// `ThreadEntryView`(→`ThreadDetailView`、Task #136 以降は常にこの1画面
    /// — 選択画面は介在しない) がこの`NavigationStack`の中で描画される。
    private var detailColumn: some View {
        NavigationStack {
            Group {
                if let pushOpenRoute {
                    // 通知の本体タップ — 対象が未同期でもまずローディングを
                    // 右ペインに出す。一覧タップ (`selectedRoute`変化) で
                    // 閉じる (`handleSelectedRouteChanged`)。
                    PushNotificationOpenView(
                        accountId: pushOpenRoute.accountId, uidNext: pushOpenRoute.uidNext, onReply: onReply, onForward: onForward,
                        onSearchFromSender: { query in openSearch(presetQuery: query) },
                        onThreadRemoved: handlePushOpenThreadRemoved
                    )
                    .id(pushOpenRoute)
                } else if let selectedRoute {
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
                if showsAccountFilterChipRow {
                    AccountFilterChipRow(accounts: environment.accounts, selectedAccountId: $accountFilter)
                }
                // 実機フィードバック (2026-07-29): ダイジェストの一括操作の
                // トーストも `MessageListView` と同じ委譲でこの画面の
                // FAB より手前に描く (`AccountDigestView
                // .suppressInternalUndoToast` の doc comment 参照)。
                AccountDigestView(
                    role: digestRole,
                    onSelectAccount: selectDigestAccount,
                    suppressInternalUndoToast: true,
                    onPendingUndoChanged: { pendingUndoPayload = $0 }
                )
            } else {
                if showsAccountFilterChipRow {
                    AccountFilterChipRow(accounts: environment.accounts, selectedAccountId: $accountFilter)
                }
                MessageListView(
                    selection: mailSelection,
                    unifiedInboxAccountFilter: accountFilter,
                    selectedThreadId: selectedThreadIdBinding,
                    selectedMessageId: selectedMessageIdBinding,
                    onSelectionModeChanged: { isSelecting = $0 },
                    onSummariesChanged: { currentThreadOrder = $0 },
                    onUnreadCountChanged: { currentUnreadCount = $0 },
                    suppressInternalUndoToast: true,
                    onPendingUndoChanged: { pendingUndoPayload = $0 }
                )
            }
        }
        // Liquid Glass Phase 1 (2026-08-07、docs/design-system.md「Liquid
        // Glass 方針」): iOS 独自の`OtegamiColor.background`塗りを廃止し、
        // 標準の画面背景へ委譲 (`MessageListView.messageListCore`の同日
        // コメント参照)。
        // Task #131 (一覧FABのspeed-dial化): 旧・左下`floatingSearchButton`
        // + 右下`floatingComposeButton`の2個独立配置を廃止し、右下1個の
        // speed-dial FAB (`SpeedDialFAB`) に統合した — 一覧のスクロール
        // 位置に関わらず常に同じ場所にある方が押しやすい、という元の判断
        // 自体は変えていない。選択モード中はヘッダ自体が丸ごとキャンセル/
        // 選択数/全選択に差し替わる (`toolbarContent`) が、FAB自体は
        // `content`側にあるため`isSelecting`と無関係に出続ける — ボタンが
        // 一括操作の邪魔にならないよう非表示にする。
        //
        // Liquid Glass Phase 1 (2026-08-07): `speedDialFAB`(このView自身の
        // 薄いプロパティ) から、`GlassEffectContainer` + `Namespace`を own
        // する独立`View`型`SpeedDialFAB`(このファイル下部) に切り出した —
        // `docs/ci.md`の「`GlassEffectContainer`の中身は独立したView型に
        // 切り出す」方針、および`@Namespace`は宣言したView自身が保持する
        // 必要があるため。
        .overlay(alignment: .bottomTrailing) {
            if !isSelecting {
                SpeedDialFAB(
                    isExpanded: $isFabExpanded,
                    accountsEmpty: environment.accounts.isEmpty,
                    onSearch: { collapseAndPerform { openSearch() } },
                    onCompose: { collapseAndPerform(onCompose) }
                )
            }
        }
        // Task #108 (実機報告「元に戻すトーストが検索・新規作成 FAB の
        // 背面に描画され重なる」): このoverlayは上の`speedDialFAB`(Task #131
        // で統合、旧`floatingSearchButton`/`floatingComposeButton`)より
        // **後**に付けている — SwiftUI の`.overlay`チェーンは後から適用した
        // ものほど手前に描画されるため、ここに置くだけでFABより確実に手前に
        // なる (`.zIndex`はチェーンが生成する各`ZStack`の中でしか効かず、
        // この階層をまたいでは効かないため、根本修正はこの「最後に付ける」
        // という位置そのもの — 明示`.zIndex`は下記の通り保険として併記)。
        // 縦位置もFABの上端 (フローティングボタンの直径+底からの余白) を
        // 確実に超える位置まで持ち上げ、重なり自体を無くす
        // (`MessageListView`が以前担っていたクリアランス計算をここに集約した
        // — `pendingUndoPayload`のdoc comment参照)。
        //
        // **実機報告 (2026-07-29)**: 「元に戻す」トーストがFABに重なって押せ
        // ないことがある。上のコメントは元々「展開中のspeed-dial子ボタンは
        // トースト表示中には両立しない (子ボタンをタップした瞬間に畳んで
        // からアクションを実行する`collapseAndPerform(_:)`)」という前提で
        // クレランスを畳んだ状態の1個ぶんの直径のまま固定していたが、これは
        // 誤りだった — `pendingUndoPayload`はFAB経由の操作 (`collapseAndPerform`)
        // 以外からも立つ (`MessageListView`の行スワイプでのアーカイブ等、
        // `onPendingUndoChanged`はFABの状態と完全に無関係)。「…」をタップして
        // FABを展開したまま (`isFabExpanded == true`)、その状態で(FABの子
        // ボタンを一切介さず)行をスワイプアーカイブすると、畳んだ状態1個分
        // のクレランスのままトーストが浮くため、実際に3個ぶん(検索/新規作成/
        // 「…」)積み上がった展開中FABの上部と重なってしまう。`floatingButtonClearance`
        // 自体を`isFabExpanded`に応じて可変にし、展開中は子ボタン2個ぶん
        // (直径+`VStack`の`spacing`) を追加で確保するよう修正した — z順序
        // (このoverlayが後述のため常に手前) 自体は元から問題なかったので
        // そのまま、縦方向のクレランス計算だけを両状態に対応させた。
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
        // 実機報告 (2026-07-29) への追記: `floatingButtonClearance`の可変化
        // (上記) に加え、トースト自体が立った瞬間にFABを畳んでおく —
        // 「展開中FAB + トースト」という組み合わせをそもそも作らない、
        // より直接的な対処。`onUndo`/自動消滅どちらでトーストが消えても
        // `isFabExpanded`はfalseのままなので、ユーザーが望めばまた
        // タップして展開し直せる (再展開の妨げにはならない)。
        // `UndoToastPayload`自体は`onUndo`クロージャを持つため`Equatable`
        // ではない — `nil`かどうかの`Bool`だけを追跡すれば
        // 「トーストが(何も無い状態から)出現した」変化を拾うのに十分。
        .onChange(of: pendingUndoPayload == nil) { _, isNil in
            if !isNil {
                isFabExpanded = false
            }
        }
    }

    /// Task #108: FAB (`floatingSearchButton`/`floatingComposeButton`、
    /// `OtegamiFloatingButtonChromeModifier`) の円の直径 + その`overlay`
    /// 自身の`.padding(.bottom, OtegamiSpacing.lg)`を、既存のトークンの
    /// 組み合わせだけで再現した値 — マジックナンバーを新設しない
    /// (`MessageListView`の旧実装のコメントと同じ方針)。円の直径は
    /// `OtegamiFloatingButtonIconModifier`の`frame`(`.xl + .xs`)と
    /// `padding`(`.md + .xs`を両側)の合計、そこにボタン自身の下端余白
    /// (`.lg`)と、トーストとの間に一呼吸ぶんの余白 (`.sm`)を足す
    /// (Liquid Glass Phase 1 でこの拡張は円の塗り自体は描かなくなった
    /// — `OtegamiFloatingButton.swift`のdoc comment参照 — が、アイコンの
    /// `frame`/`padding`のサイズ自体は変えていないので、ここでの円の直径
    /// 計算は引き続き有効)。
    ///
    /// **実機報告 (2026-07-29) への追記**: Task #131 の speed-dial 化以降、
    /// この円1個ぶんの高さは「畳んだ状態」のFABにしか正しくない —
    /// `isFabExpanded`が`true`の間は`SpeedDialFAB`の`VStack`が検索/新規作成
    /// の子ボタン2個ぶん (同じ円の直径 + `VStack(spacing: .md)`の間隔) を
    /// 追加で積み上げるため、畳んだ状態基準の固定値のままだとトーストが
    /// その分だけFABに重なる (`.overlay`のdoc comment参照)。展開中は子ボタン
    /// 1個につき「直径 + `spacing`」ぶんを追加する。
    private var floatingButtonClearance: CGFloat {
        let circleDiameter = (OtegamiSpacing.xl + OtegamiSpacing.xs) + 2 * (OtegamiSpacing.md + OtegamiSpacing.xs)
        let childButtonCount = isFabExpanded ? 2 : 0
        let expandedChildrenHeight = CGFloat(childButtonCount) * (circleDiameter + OtegamiSpacing.md)
        return circleDiameter + expandedChildrenHeight + OtegamiSpacing.lg + OtegamiSpacing.sm
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

    /// チップ行 (`AccountFilterChipRow` — 「すべて ▸ 時系列/アカウント別」の
    /// プルダウン + アカウント絞り込みチップ) を出すかどうか。
    ///
    /// 実機フィードバック (2026-07-30「受信トレイ以外にも、アカウントの個別
    /// フォルダでない場合はこれを出して欲しい」): 元は
    /// `isUnifiedInboxSelected` (統合受信トレイのみ) を条件にしていたため、
    /// 「すべてのメール」/アーカイブ/ゴミ箱/送信済み/フラグ付き等の統合
    /// ビュー (`.unifiedRole`) ではアカウント絞り込みも時系列↔アカウント別の
    /// 切り替えもできなかった。複数アカウントを横断している以上、チップ行の
    /// 意味は受信トレイと全く同じなので条件を`.unifiedRole`にも広げる。
    /// 単一アカウントの個別フォルダ (`.mailbox`) だけは従来どおり出さない —
    /// 絞り込む先が1つしか無く、`AccountDigestView`(アカウント別) も
    /// `isAccountDigestEligible`で`false`になる選択なので、チップ行を置いても
    /// 操作できるものが何も無い。
    private var showsAccountFilterChipRow: Bool {
        switch mailSelection {
        case .unifiedInbox, .unifiedRole: true
        case .mailbox: false
        }
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
                // Task #74 → ヘッダ件数表示のメッセージ単位未読数化
                // (ユーザー指示、2026-07-29): タイトル横の数字は元々
                // `currentThreadOrder.count`(「今表示されてる件数」— スレッド
                // 集約時はスレッド数、ページングで切られた読み込み済み行数)
                // だったが、「スレッド表示 ON のとき、スレッド数ではなく
                // メッセージ単位の未読数を出したい (スレッドが4つでも未読が
                // 6件ならヘッダは6)」という要望で`currentUnreadCount`
                // (`MessageListView.onUnreadCountChanged`、現在の
                // `mailSelection`スコープのメッセージ単位未読数 — ページング・
                // 未読のみ表示・スレッド/フラット表示のどれにも左右されない)
                // に置き換えた。0件でも非表示にはしない — 元の実装が
                // `environment.accounts.isEmpty`だけをゲートにしていた挙動を
                // そのまま踏襲。
                HStack(spacing: OtegamiSpacing.xs) {
                    headerTitleMenu
                    if !environment.accounts.isEmpty {
                        Text("(\(currentUnreadCount))")
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
                // Task #142 のピン留めフィルタトグルは実機フィードバック
                // (2026-07-29「メール一覧のピン留めボタンを削除して」) で
                // 撤去した — 絞り込み設定キー/クエリ側 (`pinnedOnlyKey`) は
                // 残っているが、この画面からの切替 UI は無い (常に OFF)。
                unreadOnlyToggleButton
            }
        }
    }

    /// ユーザー要望 (2026-08-02「ヘッダの『すべての受信』などの部分を押すと、
    /// プルダウンでハンバーガーメニューにあるアカウントごとじゃないやつを
    /// 選べるようにして欲しい」): ヘッダタイトルをタップすると
    /// `FolderListSheet`のカテゴリセクション見出しタップと同じ横断ビュー
    /// (受信トレイ/フラグ付き/アーカイブ/すべてのメール/送信済み/下書き/
    /// 迷惑メール/ゴミ箱) をその場で選べる`Menu`。個別メールボックス選択中
    /// (`.mailbox`) でも常に出す — そこから他の横断ビューへ直接切り替えられ
    /// た方が、一度ハンバーガーメニューを開き直すより便利なため。選択後の
    /// 状態遷移は既存の`selectUnifiedInbox()`/`selectUnifiedRole(_:)`を
    /// そのまま呼ぶだけ (ハンバーガーメニュー側の同じ行が呼んでいるのと同じ
    /// 関数)。
    private var headerTitleMenu: some View {
        Menu {
            ForEach(headerMenuCategoryOrder, id: \.self) { role in
                HeaderCategoryMenuRow(
                    role: role,
                    isSelected: isHeaderMenuRoleSelected(role),
                    action: { selectFromHeaderMenu(role) }
                )
            }
        } label: {
            HStack(spacing: 2) {
                Text(selectionTitle)
                    .font(OtegamiFont.headline())
                    .foregroundStyle(OtegamiColor.ink)
                    .accessibilityIdentifier("mail.title")
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(OtegamiColor.inkSecondary)
            }
        }
        .accessibilityIdentifier("mail.titleMenu")
    }

    private var headerMenuCategoryOrder: [MailboxRoleRecord] {
        FolderCategoryOrderStore.loadOrder(from: headerMenuCategoryOrderRaw)
    }

    private func isHeaderMenuRoleSelected(_ role: MailboxRoleRecord) -> Bool {
        role == .inbox ? isUnifiedInboxSelected : selectedUnifiedRole == role
    }

    private func selectFromHeaderMenu(_ role: MailboxRoleRecord) {
        if role == .inbox {
            selectUnifiedInbox()
        } else {
            selectUnifiedRole(role)
        }
    }

    /// 実装ルール: 「再読込ボタンは不要 (pull-to-refresh で足りる)、その代わり
    /// 未読のみ表示のトグルをヘッダに」。真偽値そのものは`isUnreadOnly`
    /// (`ListDisplaySettingsStore.unreadOnlyKey`の`@AppStorage`) — 実際の
    /// 絞り込みは`MessageListView.observeThreads()`側で行われる。
    ///
    /// **方針転換 (Liquid Glass Phase 1, 2026-08-07)**: 旧実装は
    /// `.buttonStyle(.plain)`で iOS 26 系の Liquid Glass ツールバーボタンの
    /// 自前ティント丸背景を意図的に抑止し、ON/OFF を`OtegamiColor
    /// .accentText`/`.paleBaseStrong`という独自の塗り+文字色だけで表現して
    /// いた (「新しい色をその場で追加しない」ため既存トークンを再利用した
    /// 判断自体は妥当だったが、クローム層の独自塗りという点で Liquid Glass
    /// 方針とは逆行していた)。`docs/design-system.md`の Liquid Glass 方針
    /// 採用に伴い、まさにその「抑止していたシステム標準のティントガラス」
    /// へ委譲する形へ転換した — `Toggle(isOn:)` + `.toggleStyle(.button)`
    /// にすることで ON 時の塗りはシステムの Glass ボタンに任せ、
    /// `.tint(OtegamiColor.accent)`でアクセント色だけ指定する。シンボルの
    /// fill/outline 切替 (`envelope.badge.fill`/`envelope.badge`) は保険と
    /// して維持 — Glass の塗り変化に加えて形でも ON/OFF が分かるように。
    private var unreadOnlyToggleButton: some View {
        Toggle(isOn: $isUnreadOnly) {
            Label("未読のみ表示", systemImage: isUnreadOnly ? "envelope.badge.fill" : "envelope.badge")
                .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .tint(OtegamiColor.accent)
        .accessibilityIdentifier("mail.unreadOnlyToggle")
        .accessibilityAddTraits(isUnreadOnly ? .isSelected : [])
    }


    /// 子ボタン共通の「実行して畳む」— どちらの子ボタンも「タップで実行 +
    /// 自動で畳む」という同じ仕様なので、この1箇所にまとめてある。
    private func collapseAndPerform(_ action: () -> Void) {
        isFabExpanded = false
        action()
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
            showingFolderMenu.toggle()
        } label: {
            Label("メニュー", systemImage: "line.3.horizontal")
        }
        .accessibilityIdentifier("mail.hamburgerButton")
    }

    private var menuContent: some View {
        FolderListSheet(
            selectedMailboxId: selectedMailboxId,
            onSelectMailbox: selectMailbox,
            onOpenOutbox: { presentAfterClosingMenu { showingOutbox = true } },
            onOpenDrafts: { presentAfterClosingMenu { showingDrafts = true } },
            onOpenFailedOps: { presentAfterClosingMenu { showingFailedOps = true } },
            onAddAccount: { presentAfterClosingMenu { accountEntryRoute = .typeSelection } },
            onOpenSettings: { presentAfterClosingMenu { showingSettings = true } },
            onClose: { showingFolderMenu = false }
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
        showingFolderMenu = false
    }

    private func selectMailbox(_ mailboxSelection: MailboxSelection, _ displayName: String) {
        mailSelection = .mailbox(mailboxSelection)
        selectionTitle = displayName
        accountFilter = nil
        showingFolderMenu = false
    }

    /// 画面構造改修バッチ (Task #33, 3): カテゴリ優先メニューの「横断ビュー」行
    /// (例:「すべてのアーカイブ」) — `selectUnifiedInbox()`のrole一般化版。
    /// `accountFilter`は`.unifiedInbox`専用の1a絞り込みチップ用状態なので、
    /// ここでも念のため`nil`にリセットしておく (`.unifiedRole`selectionでは
    /// そもそも`AccountFilterChipRow`自体を出さないので実質無害だが、
    /// `selectMailbox`/`selectUnifiedInbox`と同じ後始末を揃えておく)。
    private func selectUnifiedRole(_ role: MailboxRoleRecord) {
        mailSelection = .unifiedRole(role)
        // 実機フィードバック (Task #141): `MessageListView.title`の同じ
        // 分岐のdoc comment参照 — `role == .all`の`categoryDisplayName`
        // 自体が「すべてのメール」なので、テンプレートを適用すると
        // 「すべてのすべてのメール」に二重化する。
        selectionTitle = role == .all ? role.categoryDisplayName : String(localized: "すべての\(role.categoryDisplayName)")
        accountFilter = nil
        showingFolderMenu = false
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
        // Task #140: a single atomic `@State` write — see `searchRoute`'s
        // doc comment for why this replaced the old two-separate-`@State`
        // (`showingSearch`/`searchPresetQuery`) shape. A fresh `SearchSheetRoute`
        // every call (not reusing an existing non-nil one) also means two
        // "search from sender" taps in a row for *different* senders always
        // present as a genuinely new sheet identity, even on the rare chance
        // both resolve to the same `presetQuery` string.
        searchRoute = SearchSheetRoute(presetQuery: presetQuery)
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

    /// `FolderListSheet`'s rows all present *another* sheet. Liquid Glass
    /// Phase 3 (2026-08-07) made the folder menu itself a real `.sheet`
    /// again (`HamburgerMenuContainer`, the leading-edge drawer that
    /// sidestepped this, is gone) — so presenting the next sheet in the
    /// same call that closes this one risks this app's confirmed-broken
    /// "sheet from a sheet" nesting (see `ComposerView.swift`'s same-named
    /// known-issue comment). This just records which sheet to open next and
    /// closes the menu; `handleFolderMenuDismissed()` (invoked by this
    /// view's `.sheet(isPresented: $showingFolderMenu, onDismiss:)`) fires
    /// the closure only after the menu's dismiss animation has actually
    /// finished — the same `pendingPostFolderAction` + `onDismiss` idiom
    /// design-phase-2's original `.sheet`-based folder list needed, and
    /// that the drawer design let this app drop for a while.
    private func presentAfterClosingMenu(_ present: @escaping () -> Void) {
        pendingPostFolderAction = present
        showingFolderMenu = false
    }

    /// See `presentAfterClosingMenu(_:)`'s doc comment.
    private func handleFolderMenuDismissed() {
        pendingPostFolderAction?()
        pendingPostFolderAction = nil
    }
}

/// `MailScreenView.headerTitleMenu`の`ForEach`中身 — `docs/ci.md`の
/// SwiftUI body肥大化ルールどおり独立`View`に切り出す。選択中の行はアイコン
/// を`checkmark`に差し替える (`FolderListSheet`のカテゴリ見出しが持つ選択
/// ハイライトを、`Menu`項目としても分かるようにするための表現)。
private struct HeaderCategoryMenuRow: View {
    let role: MailboxRoleRecord
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: isSelected ? "checkmark" : role.categorySystemImage)
        }
    }

    private var title: String {
        role == .inbox ? String(localized: "すべての受信") : role.categoryDisplayName
    }
}

/// Task #131 (一覧FABのspeed-dial化)、Liquid Glass Phase 1 (2026-08-07):
/// 右下1個の speed-dial FAB — 畳んだ状態は「…」の丸ボタン1個だけ、タップ
/// するとその真上に「新規作成」「検索」("…"に近い方から新規作成→検索の順)
/// が縦に展開する。子ボタンをタップすると対応するアクションを実行しつつ
/// 自動で畳む (呼び出し元の`onSearch`/`onCompose`クロージャが
/// `MailScreenView.collapseAndPerform(_:)`で包んでいる)。展開状態
/// (`isExpanded`) 自体は永続化しない — 呼び出し元 (`MailScreenView`) の
/// `@State`をそのまま`@Binding`で受け取るだけ。
///
/// `GlassEffectContainer` + `@Namespace` + 各ボタンの
/// `glassEffect(_:in: .circle)` + `glassEffectID(_:in:)`で「…」⇄「検索/
/// 新規作成」間の展開/収納を Liquid Glass のモーフィングとして表現する —
/// `docs/design-system.md`の Liquid Glass 方針、`docs/ci.md`の
/// 「`GlassEffectContainer`の中身は独立したView型に切り出す」の両方に
/// 従い、`MailScreenView.content`から独立したこの`View`型に切り出した
/// (`@Namespace`はそれを宣言したView自身が保持する必要があるため、
/// `MailScreenView`側に置くと元の`speedDialFAB`という薄いプロパティには
/// 収まらなかった)。
///
/// compose (新規作成) ボタンだけ`.tint(OtegamiColor.accent)`付きの tinted
/// glass (`.glassProminent`相当の強調) — 検索/「…」は素の`.regular`
/// Glass。実機フィードバック第4弾以来「全部のフローティングボタンを
/// アクセント塗りに統一」だった判断を、Liquid Glass 方針の「tint 付き
/// Glass は compose 系の最重要アクションに限る」に合わせて絞り込んだ。
private struct SpeedDialFAB: View {
    @Binding var isExpanded: Bool
    let accountsEmpty: Bool
    let onSearch: () -> Void
    let onCompose: () -> Void

    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: OtegamiSpacing.md) {
            VStack(alignment: .trailing, spacing: OtegamiSpacing.md) {
                if isExpanded {
                    SpeedDialChildButton(
                        title: "検索", systemImage: "magnifyingglass", accessibilityId: "mail.searchButton",
                        namespace: glassNamespace, action: onSearch
                    )
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                    SpeedDialChildButton(
                        title: "新規作成", systemImage: "square.and.pencil", accessibilityId: "mail.composeButton",
                        namespace: glassNamespace, isProminent: true, action: onCompose
                    )
                    .disabled(accountsEmpty)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                fabToggleButton
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isExpanded)
        .padding(.trailing, OtegamiSpacing.lg)
        .padding(.bottom, OtegamiSpacing.lg)
    }

    /// speed-dial FABの起点ボタン ("…" / 展開中は"×") — タップのたびに
    /// `isExpanded`をトグルするだけ。`.contentTransition(.symbolEffect
    /// (.replace))`でアイコン切り替え自体をアニメーションさせる
    /// (仕様「展開中の「…」は活性表示 (×へ回転等)」)。
    private var fabToggleButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: isExpanded ? "xmark" : "ellipsis")
                .contentTransition(.symbolEffect(.replace))
                .otegamiFloatingButtonIcon()
                .foregroundStyle(OtegamiColor.accent)
                // 実機報告 (2026-08-07)「右下の … ボタンを押しても何も
                // 出なくなっている」: Liquid Glass Phase 1 で
                // `OtegamiFloatingButtonChromeModifier`の`Circle()`塗りを
                // 廃止した (`OtegamiFloatingButton.swift`のdoc comment) 結果、
                // このボタンには**不透明な背景が1つも無くなった** —
                // `.buttonStyle(.plain)`のヒットテストは描画された内容の
                // 形にそのまま従うので、当たり判定が「…」の点3つ (と
                // `xmark`の線) だけに縮み、円の余白部分をタップしても何も
                // 起きない状態になっていた。`glassEffect`が描くガラスは
                // 装飾であってヒットテストには寄与しない。`glassEffect(in:)`
                // と同じ円形を`contentShape`にも与えて、見えている円全体を
                // タップ領域に戻す。
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("fabToggle", in: glassNamespace)
        .accessibilityIdentifier("mail.fabToggleButton")
        .accessibilityLabel(isExpanded ? Text("閉じる") : Text("その他のアクション"))
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
    }
}

/// `SpeedDialFAB`の子ボタン1個ぶん — `docs/ci.md`の「`ForEach`/条件分岐の
/// 中身は独立したView型に切り出す」方針どおり、`SpeedDialFAB.body`を薄い
/// ままに保つための切り出し。`namespace`は`SpeedDialFAB`自身が持つ
/// `@Namespace`を受け取り、「…」ボタンと同じ名前空間の`glassEffectID`で
/// モーフィングに参加する。
private struct SpeedDialChildButton: View {
    let title: String
    let systemImage: String
    let accessibilityId: String
    let namespace: Namespace.ID
    /// compose のみ`true` — tint 付き Glass で最重要アクションを目立たせる
    /// (`SpeedDialFAB`の doc comment参照)。
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .otegamiFloatingButtonIcon()
                .foregroundStyle(isProminent ? Color.white : OtegamiColor.accent)
                // `SpeedDialFAB.fabToggleButton`と同じ理由 (実機報告
                // 「… ボタンを押しても何も出ない」) — 円塗りを失った
                // ボタンは、明示しないとアイコンの描画部分しかタップ
                // できない。
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(
            isProminent ? .regular.tint(OtegamiColor.accent).interactive() : .regular.interactive(),
            in: .circle
        )
        .glassEffectID(accessibilityId, in: namespace)
        .accessibilityIdentifier(accessibilityId)
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

/// `MailScreenView.pushOpenRoute`の navigation item — 通知の本体タップが
/// 運ぶ**未解決**の対象 (`PushNotificationOpenRequest`と同じ accountId/
/// uidNext)。`ThreadRoute`と同じ「destination が必要な値はすべて item 自身
/// が運ぶ」idiom。`id`は内容から導出 — 同じ通知を (一度閉じてから) もう一度
/// タップしたケースは binding が一旦 nil に戻っているので、同値でも再push
/// される。
private struct PushOpenRoute: Hashable, Identifiable {
    let accountId: String
    let uidNext: Int
    var id: String { "\(accountId)#\(uidNext)" }
}

/// Task #140: `MailScreenView.searchRoute`'s item type — bundles
/// `presetQuery` into the same value that drives `.sheet(item:)`'s
/// presentation, the same "everything the destination needs travels in the
/// item itself" idiom `ThreadRoute`'s doc comment above establishes (that
/// one for `.navigationDestination(item:)`, this one for a `.sheet`). A
/// fresh `UUID` per `SearchSheetRoute(presetQuery:)` call (not derived from
/// `presetQuery` itself) is deliberate: `.sheet(item:)` only re-presents
/// when the item's `id` actually changes, and two consecutive "search from
/// sender" taps could otherwise resolve to the *same* `presetQuery` string
/// (same sender, tapped twice) — an id keyed off content would then fail to
/// trigger a second presentation at all.
private struct SearchSheetRoute: Identifiable {
    let id = UUID()
    let presetQuery: String?
}
