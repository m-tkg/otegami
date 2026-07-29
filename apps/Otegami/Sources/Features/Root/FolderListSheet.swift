import SwiftUI
import GRDB
import OtegamiStore
import SyncEngine

/// iOS-only (新画面構成 (1)): the content of `MailScreenView`'s hamburger-
/// menu drawer (`HamburgerMenuContainer`) — formerly a modal `.sheet`
/// (design-phase-2's 1a), now permanently mounted inside the drawer and
/// slid in/out instead of presented/dismissed. Content mirrors what
/// `SidebarView` (macOS's permanently-visible left column) shows — unified
/// inbox row, outbox/drafts/sync-error banners, each account's mailbox
/// tree — plus 設定 pinned at the bottom (`settingsSection`, 新画面構成 (1):
/// "設定はそのメニューの一番下に配置"). Deliberately a *separate* type from
/// `SidebarView` rather than a shared extraction: this view owns its own
/// `ValueObservation`s (mailboxes, unread counts, outbox/draft/error
/// counts) with the same shape as `SidebarView`'s, but the two are
/// presented completely differently (an always-visible `NavigationSplitView`
/// column vs. a sliding drawer) and `SidebarView` is macOS-only from here
/// on — keeping them independent avoids coupling two screens that no longer
/// share a rendering context, at the cost of the observation logic living
/// in two places. See `docs/design-system.md` for the tradeoff this task
/// recorded.
///
/// Rows that need to present something (送信待ち/下書き/同期エラー/設定/
/// アカウント追加) don't do so directly from here — they call an `onOpen*`
/// closure that asks `MailScreenView` (the common ancestor) to close the
/// drawer and present that sheet. Historically (design-phase-2) this
/// indirection existed because this view itself used to be a `.sheet`, and
/// a sheet-presented-from-a-sheet was a confirmed-broken nesting depth in
/// this app; now that this view is a drawer rather than a sheet, that
/// specific hazard is gone, but the `onOpen*` closures remain the simplest
/// way for a common ancestor that already owns every target `@State` flag
/// to coordinate "close the drawer, then open the next thing" in one place
/// (`MailScreenView.presentAfterClosingMenu(_:)`).
struct FolderListSheet: View {
    @Environment(AppEnvironment.self) private var environment

    let selectedMailboxId: Int64?
    let isUnifiedInboxSelected: Bool
    /// 画面構造改修バッチ (Task #33, 3): カテゴリ優先メニューの「横断ビュー」行
    /// (例:「すべてのアーカイブ」)がハイライトされるべき role — 現在の
    /// `MailScreenView.mailSelection`が`.unifiedRole(role)`ならその`role`、
    /// それ以外 (`.mailbox`/`.unifiedInbox`) なら`nil`。`selectedMailboxId`が
    /// `.mailbox`専用なのと対になる、もう一つの「今どれが選ばれているか」入力。
    let selectedUnifiedRole: MailboxRoleRecord?
    var onSelectUnified: () -> Void
    var onSelectMailbox: (MailboxSelection, String) -> Void
    /// 画面構造改修バッチ (Task #33, 3): カテゴリ優先メニューの「横断ビュー」行
    /// — タップされた role を渡す。`onSelectMailbox`が特定の1メールボックス
    /// (`MailboxSelection`)を渡すのに対し、こちらは「この role のメールボックス
    /// を持つ全アカウントをまとめて見る」という role 単位の選択。
    var onSelectUnifiedRole: (MailboxRoleRecord) -> Void
    var onOpenOutbox: () -> Void
    var onOpenDrafts: () -> Void
    var onOpenFailedOps: () -> Void
    var onOpenMailboxSyncFailures: () -> Void
    var onAddAccount: () -> Void
    /// 新画面構成 (1): メニュー最下部の「設定」行。
    var onOpenSettings: () -> Void
    /// Task #73: ドロワーの開閉状態そのもの — `MailScreenView.isMenuOpen`が
    /// そのまま渡ってくる。このビューは`HamburgerMenuContainer`の doc
    /// comment通り常設マウントされたまま`offset`でスライドするだけなので、
    /// `.sheet`のような「開くたびに再生成される」ライフサイクルが無い。
    /// 「開いた時は全折りたたみ＋選択中のみ展開」を実現するには、この値の
    /// 変化 (`false`→`true`) を`.onChange`で拾って毎回明示的にリセットする
    /// しかない — `resetCollapseStateToCurrentSelection()`参照。
    let isMenuOpen: Bool
    /// 新画面構成 (1): "閉じる" ツールバーボタン — このビューはもう `.sheet`
    /// ではなくドロワーとして常設マウントされているため、`@Environment
    /// (\.dismiss)` は使えない (呼び出しても何も起きない、提示コンテキストが
    /// 無いため)。`MailScreenView` が `isMenuOpen` を渡してドロワーを閉じる。
    var onClose: () -> Void

    @State private var mailboxesByAccountId: [String: [MailboxRecord]] = [:]
    @State private var outboxCount = 0
    @State private var draftCount = 0
    @State private var failedOpCount = 0
    @State private var mailboxSyncFailureCount = 0
    @State private var unreadByMailboxId: [Int64: Int] = [:]
    @State private var unifiedInboxUnread = 0
    /// K (実機フィードバック第3弾): which accounts' mailbox trees are
    /// currently collapsed — seeded once from `FolderSectionCollapseStore`
    /// (persisted `UserDefaults`) so a relaunch remembers what the user
    /// last chose, then kept in sync with every toggle
    /// (`toggleAccountCollapsed(_:)`). Not present in the set = expanded
    /// (the default for an account never explicitly collapsed).
    @State private var collapsedAccountIds: Set<String> = FolderSectionCollapseStore.collapsedAccountIds
    /// 画面構造改修バッチ (Task #33, 3): カテゴリ優先メニューの折りたたみ状態 —
    /// `collapsedAccountIds`(アカウント優先メニュー用)とは別の永続キーで管理
    /// する。「既存の折りたたみ(FolderSectionCollapseStore)…を尊重」の要件は
    /// アカウント優先モード自身の折りたたみ状態を変えない、という意味であって、
    /// 表示単位そのものが違うカテゴリ優先モードに同じ折りたたみ状態を無理に
    /// 使い回す理由にはならない。
    @State private var collapsedCategoryRoles: Set<String> = FolderCategoryCollapseStore.collapsedRoleRawValues
    /// Task #52 追記: 「カテゴリ優先/アカウント優先のセグメント切替
    /// (`FolderGroupingMode`)」は廃止し、Spark と同じく1枚のリストにカテゴリ
    /// 群 (上) →アカウント群 (下、従来のアカウント優先表示の内容そのまま)を
    /// 縦に積む構成にした。カテゴリセクション自体の並び順だけがユーザーに
    /// 開放されている (`FolderCategoryOrderStore`) — `@AppStorage`で生の
    /// 文字列を直接監視するのは`FolderCategoryOrderStore.loadOrder(from:)`
    /// のdoc comment参照 (このビューは常設マウントのドロワーで再生成され
    /// ないため、設定画面での変更を反応的に拾う必要がある)。
    @AppStorage(FolderCategoryOrderStore.key) private var categoryOrderRaw = ""
    private var categoryOrder: [MailboxRoleRecord] {
        FolderCategoryOrderStore.loadOrder(from: categoryOrderRaw)
    }

    /// 実機フィードバック第2弾 (2026-07-29「一番下にある項目を開いたとき、
    /// 開かれてることに気づきにくい」): セクションを展開した直後に、その
    /// 見出しを画面上部へ自動スクロールするためのターゲット。トグル関数が
    /// 展開時にセクション見出しの `.id` をここへ入れ、`ScrollViewReader` の
    /// `.onChange` が拾って `scrollTo(_:anchor: .top)` する — 展開行が画面
    /// 外 (下) に伸びるだけで何も動かないように見える問題への対策。
    @State private var menuScrollTarget: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                if environment.accounts.isEmpty {
                    ContentUnavailableView {
                        Label("アカウントがありません", systemImage: "envelope.badge")
                    } description: {
                        Text("メールアカウントを追加してください。")
                    } actions: {
                        Button("アカウントを追加") { onAddAccount() }
                            .accessibilityIdentifier("folderSheet.addAccountButton")
                    }
                } else {
                    statusSection
                    // Task #52 追記: カテゴリ群 (上) →アカウント群 (下) の
                    // 縦積み構成 — Spark のメニューと同じ (旧セグメント切替
                    // 廃止の経緯は`categoryOrder`のdoc comment参照)。
                    ForEach(categoryOrder, id: \.self) { role in
                        categorySection(for: role)
                    }
                    // Task #126, 3: 「その他」(role で分類できない = #119の
                    // ロール補完後もなお未分類なフォルダ) の専用セクションは
                    // 廃止した — 該当フォルダは下のアカウント別ツリー
                    // (`accountSection(for:)`、全メールボックスを role 問わず
                    // 表示) に引き続き現れるので、メニューから消えるわけでは
                    // ない。旧`uncategorizedSection`/`categoryMailboxRow(for:)`
                    // はもう存在しない — `docs/design-system.md`にこの判断を
                    // 記録した。
                    ForEach(environment.accounts) { account in
                        accountSection(for: account)
                    }
                }
            }
            .accessibilityIdentifier("folderSheet.list")
            // 実機フィードバック第3弾 (2026-07-29「まだ『受信トレイ』とか
            // 『フラグ付き』とかの高さが高い」): 行高そのものは 6257a0d で
            // 圧縮済み — 残っていた高さの正体はセクション見出し行の上下に
            // つく List 既定のセクション間余白。`.listSectionSpacing` で
            // セクション間を最小に詰める。`FolderListSheet`自体は iOS 専用
            // (`HamburgerMenuContainer`のドロワーとしてのみ使われる — macOS は
            // 別の `SidebarView` を持つ) だが、この修飾子自体は macOS で
            // `unavailable` なため `#if os(iOS)` で囲まないと `make mac` の
            // ビルドを壊す (Swift はプラットフォーム間で未使用コードでも
            // 全プラットフォーム分をコンパイルする)。
            #if os(iOS)
            .listSectionSpacing(4)
            #endif
            // `menuScrollTarget` の doc comment 参照 — 展開直後に見出しを
            // 上端へスクロール。`.onChange` は展開行の insert が同じ更新
            // サイクルで確定した後に発火するため、`scrollTo` 時点で行の
            // 実体が存在する。
            .onChange(of: menuScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.default) {
                    proxy.scrollTo(target, anchor: .top)
                }
                menuScrollTarget = nil
            }
            .scrollContentBackground(.hidden)
            .background(OtegamiColor.background)
            .navigationTitle("フォルダ")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // J (実機フィードバック第3弾): アイコンのみのボタンに変更
                    // (テキストラベルだった旧実装 — `Button("閉じる")`) —
                    // `Label` の `title`/`icon` を両方渡しつつ
                    // `.labelStyle(.iconOnly)` にすることで、見た目は
                    // xmark アイコンだけになりつつ VoiceOver は "title"
                    // (=「閉じる」) をそのまま読み上げ続ける — SwiftUI の
                    // `Label` は `.iconOnly` でも `title` をアクセシビリ
                    // ティラベルとして保持する、というドキュメント通りの
                    // 挙動。
                    Button(action: onClose) {
                        Label("閉じる", systemImage: "xmark")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("folderSheet.closeButton")
                }
                // Task #126, 1: 設定ボタンをメニュー最下部の左下フローティング
                // (旧`floatingSettingsButton`) から、ヘッダ右上 (歯車アイコン)
                // へ移設した — `presentAfterClosingMenu`経由の「ドロワーを
                // 閉じてから設定シートを開く」動線 (`onOpenSettings`) 自体は
                // 変えていない、呼び出し元をこのツールバーボタンに変えただけ。
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onOpenSettings) {
                        Label("設定", systemImage: "gearshape")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("folderSheet.settings")
                }
            }
            }
        }
        .tint(OtegamiColor.accent)
        .accessibilityIdentifier("folderSheet.sheet")
        .task(id: environment.accounts.map(\.id)) { await observeOutbox() }
        .task(id: environment.accounts.map(\.id)) { await observeDraftCount() }
        .task(id: environment.accounts.map(\.id)) { await observeFailedOpCount() }
        .task(id: environment.accounts.map(\.id)) { await observeMailboxSyncFailureCount() }
        .task(id: environment.accounts.map(\.id)) { await observeUnifiedInboxUnreadCount() }
        // 画面構造改修バッチ (Task #33, 3): これまで`accountSection(for:)`の
        // `.task(id: account.id)`としてアカウント単位のSectionにぶら下がって
        // いた2つの観測を、ここへ引き上げてある — Task #52 追記でカテゴリ群/
        // アカウント群を常に両方描画する構成になった今も、`categorySection
        // (for:)`(カテゴリ群) 自体はアカウント単位のSectionを描画しない
        // (`mailboxEntries(for:)`が`mailboxesByAccountId`を横断的に読むだけ)
        // ため、この位置に置いたままにしている。
        .task(id: environment.accounts.map(\.id)) { await observeAllMailboxes() }
        .task(id: environment.accounts.map(\.id)) { await observeAllUnreadCounts() }
        // Task #73: 「開いた時は全折りたたみ＋選択中のみ展開」— ドロワーが
        // 閉→開に切り替わるたびリセットする。開いている間の手動開閉
        // (`toggleAccountCollapsed`/`toggleCategoryCollapsed`) はここでは
        // 一切妨げない (このビューは常設マウントのため、閉じている間の
        // 手動操作もそのまま次に活きてしまうが、次に開いた瞬間に必ずここで
        // 上書きされるので実害はない)。
        .onChange(of: isMenuOpen) { _, newValue in
            if newValue {
                resetCollapseStateToCurrentSelection()
            }
        }
    }

    /// Task #73: ドロワーが開かれた瞬間に呼ばれる — 現在の選択
    /// (`selectedUnifiedRole`/`selectedMailboxId`) が属するセクションだけを
    /// 展開状態にし、それ以外の全セクション (カテゴリ・アカウント両方) を
    /// 折りたたむ。`.unifiedInbox`が選択中 (どちらの入力も`nil`) の場合は
    /// 展開対象が無い = 全折りたたみになる。
    private func resetCollapseStateToCurrentSelection() {
        // Task #110 検証用: `scripts/verify-screen.sh`の`menu-expanded`
        // シナリオが、タップ (シェブロン操作) 無しで「セクション行タップ =
        // 統合ビュー選択、シェブロンは開閉専用」の見た目 (展開状態) を
        // screenshot するための直接遷移フラグ — `-uitestsOpenSettingsDirectly`
        // 等と同じ「実機/通常起動では引数に無いので常にno-op」パターン。
        if ProcessInfo.processInfo.arguments.contains("-uitestsExpandFolderMenuSectionsDirectly") {
            withAnimation(.default) {
                collapsedCategoryRoles = []
                collapsedAccountIds = []
            }
            FolderCategoryCollapseStore.replaceAll(collapsedRoleRawValues: collapsedCategoryRoles)
            FolderSectionCollapseStore.replaceAll(collapsedAccountIds: collapsedAccountIds)
            return
        }

        var expandedRoles: Set<String> = []
        var expandedAccountIds: Set<String> = []

        // 実機フィードバック第2弾 (2026-07-29「常に1つだけ開かれてる状態に
        // して」): アコーディオン化に合わせ、開いた時の展開も**最大1
        // セクション**に絞る — 以前は「選択中メールボックスのアカウント +
        // それが属するカテゴリ」の複数を同時に展開していたが、選択に一番
        // 近い1つ (role 選択中ならその role、メールボックス選択中はその
        // アカウント) だけを開く。
        if let selectedUnifiedRole {
            expandedRoles.insert(selectedUnifiedRole.rawValue)
        } else if let selectedMailboxId, let entry = accountAndMailbox(forMailboxId: selectedMailboxId) {
            expandedAccountIds.insert(entry.account.id)
        }

        let allRoleValues = Set(categoryOrder.map(\.rawValue))
        let allAccountIds = Set(environment.accounts.map(\.id))

        withAnimation(.default) {
            collapsedCategoryRoles = allRoleValues.subtracting(expandedRoles)
            collapsedAccountIds = allAccountIds.subtracting(expandedAccountIds)
        }
        FolderCategoryCollapseStore.replaceAll(collapsedRoleRawValues: collapsedCategoryRoles)
        FolderSectionCollapseStore.replaceAll(collapsedAccountIds: collapsedAccountIds)
    }

    /// 現在選択中の`mailboxId`がどのアカウント・メールボックスのものかを
    /// `mailboxesByAccountId`から引く — `resetCollapseStateToCurrentSelection()`
    /// 専用のヘルパー。
    private func accountAndMailbox(forMailboxId mailboxId: Int64) -> (account: AccountRecord, mailbox: MailboxRecord)? {
        for account in environment.accounts {
            if let mailbox = (mailboxesByAccountId[account.id] ?? []).first(where: { $0.id == mailboxId }) {
                return (account, mailbox)
            }
        }
        return nil
    }

    private func observeAllMailboxes() async {
        await withTaskGroup(of: Void.self) { group in
            for account in environment.accounts {
                group.addTask { await observeMailboxes(accountId: account.id) }
            }
        }
    }

    private func observeAllUnreadCounts() async {
        await withTaskGroup(of: Void.self) { group in
            for account in environment.accounts {
                group.addTask { await observeUnreadCounts(accountId: account.id) }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            // Task #126 追加仕様: #110 以降「受信トレイ」カテゴリセクション
            // 見出し行のタップが、この行と全く同じ統合受信トレイ選択
            // (`onSelectUnified`) になったため、この専用のピン留め行は完全に
            // 重複していた — 削除し、「受信トレイ」セクション行だけを残す。
            // 選択中ハイライトも`categorySection(for:)`側 (role`.inbox`) に
            // 移した — `isUnifiedInboxSelected`の消費先はそちらのみになった
            // (`accessibilityIdentifier`の`folderSheet.unifiedInbox`はもう
            // 存在しない — 参照 UITest がある場合は
            // `folderSheet.category.inbox.header`側を見るよう更新すること)。
            if outboxCount > 0 {
                Button {
                    onOpenOutbox()
                } label: {
                    Label("送信待ち (\(outboxCount))", systemImage: "tray.and.arrow.up")
                }
                .otegamiMenuRowChrome()
                .accessibilityIdentifier("folderSheet.outbox")
            }
            if draftCount > 0 {
                Button {
                    onOpenDrafts()
                } label: {
                    Label("下書き (\(draftCount))", systemImage: "doc")
                }
                .otegamiMenuRowChrome()
                .accessibilityIdentifier("folderSheet.drafts")
            }
            if failedOpCount > 0 {
                Button {
                    onOpenFailedOps()
                } label: {
                    Label("同期エラー (\(failedOpCount))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(OtegamiColor.destructive)
                }
                .otegamiMenuRowChrome()
                .accessibilityIdentifier("folderSheet.failedOps")
            }
            if mailboxSyncFailureCount > 0 {
                Button {
                    onOpenMailboxSyncFailures()
                } label: {
                    Label("メールボックス同期エラー (\(mailboxSyncFailureCount))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(OtegamiColor.destructive)
                }
                .otegamiMenuRowChrome()
                .accessibilityIdentifier("folderSheet.mailboxSyncFailures")
            }
        }
    }

    // Task #126, 1: 設定は左下のフローティングボタン (旧`floatingSettingsButton`)
    // だった — メニュー最上部の右上、歯車アイコンのツールバーボタンに移設
    // した (`body`の`.toolbar`内、`.confirmationAction`プレースメント)。
    // `otegamiFloatingButtonChrome()`はもうこの画面では使わない。

    /// K (実機フィードバック第3弾): one account's collapsible mailbox-tree
    /// `Section` — the header itself is a tappable row
    /// (`AccountSectionHeader`, split out for the same `docs/ci.md` reason
    /// every other row-shaped closure in this file already is) rather than
    /// `Section`'s own `String` header, since a plain `Section` header has
    /// no tap target to hang the collapse toggle off. The `ForEach` over
    /// mailboxes only renders while expanded — collapsing removes the rows
    /// from the list entirely (not just visually hidden), matching a
    /// standard disclosure-group's behavior.
    @ViewBuilder
    private func accountSection(for account: AccountRecord) -> some View {
        let isCollapsed = collapsedAccountIds.contains(account.id)
        Section {
            if !isCollapsed {
                ForEach(mailboxesByAccountId[account.id] ?? []) { mailbox in
                    folderMailboxRow(for: mailbox, in: account)
                }
            }
        } header: {
            AccountSectionHeader(
                accountId: account.id,
                labelColorKey: account.labelColorKey,
                title: account.displayName,
                unreadCount: accountUnreadCount(for: account.id),
                isCollapsed: isCollapsed,
                onToggle: { toggleAccountCollapsed(account.id) }
            )
            .id("menuSection-account-\(account.id)")
        }
    }

    /// K: the badge a collapsed account's header shows — every mailbox's
    /// unread count summed, not just the inbox's, so collapsing an account
    /// never hides unread mail the way a single-mailbox badge would.
    private func accountUnreadCount(for accountId: String) -> Int {
        (mailboxesByAccountId[accountId] ?? [])
            .compactMap(\.id)
            .reduce(0) { $0 + (unreadByMailboxId[$1] ?? 0) }
    }

    /// 実機フィードバック第2弾 (2026-07-29): アコーディオン動作 — 展開する
    /// ときは他のセクション (カテゴリ・アカウントとも) を全て畳み、常に
    /// 最大1セクションだけが開いた状態を保つ。畳む操作は単にそのセクション
    /// を閉じるだけ (全closedは許容)。
    private func toggleAccountCollapsed(_ accountId: String) {
        let collapsing = !collapsedAccountIds.contains(accountId)
        withAnimation(.default) {
            if collapsing {
                collapsedAccountIds.insert(accountId)
            } else {
                collapsedAccountIds = Set(environment.accounts.map(\.id)).subtracting([accountId])
                collapsedCategoryRoles = Set(categoryOrder.map(\.rawValue))
            }
        }
        FolderSectionCollapseStore.replaceAll(collapsedAccountIds: collapsedAccountIds)
        FolderCategoryCollapseStore.replaceAll(collapsedRoleRawValues: collapsedCategoryRoles)
        if !collapsing {
            // 展開に気づけるよう見出しを上端へ (`menuScrollTarget`参照)。
            menuScrollTarget = "menuSection-account-\(accountId)"
        }
    }

    // MARK: - 画面構造改修バッチ (Task #33, 3): カテゴリ優先グルーピング

    /// 1 role分のセクション — 「受信トレイ/アーカイブ/送信済み/下書き/ゴミ箱等の
    /// roleごとにセクションを作り、その中に各アカウントを並べる + 横断ビュー」。
    /// どの account にも `role` のメールボックスが1つも無ければセクション自体を
    /// 出さない (空の「送信済み」セクション等が並ぶのを避ける)。
    /// Task #110 (ハンバーガーメニューの挙動変更): 統合ビューを持つセクション
    /// (`.inbox`/`.flagged`/`.archive`/`.sent`/`.drafts`/`.junk`/`.trash` —
    /// `categoryOrder`のすべて) は、以前は「セクション見出し行タップ =
    /// 折りたたみ開閉」「見出し配下の専用行 (`categoryUnifiedRow`、旧実装)
    /// タップ = 統合ビュー選択」の2手段が併存していた。ユーザー要望により
    /// 見出し行本体のタップを統合ビュー選択そのものに変更し (`onSelectUnified`
    /// を渡す)、折りたたみ開閉は見出し右端のシェブロンだけが担うようにした
    /// (`onToggle`)。これにより専用行が完全に冗長になったため削除した —
    /// 旧`categoryUnifiedRow(for:entries:)`はもう存在しない。「開いた時は
    /// 選択中のセクションだけ展開」という既存の初期状態
    /// (`resetCollapseStateToCurrentSelection()`) はシェブロンの開閉状態と
    /// して変わらず維持する。
    /// Task #141: 「すべてのメール」(`role == .all`) は他カテゴリと違い
    /// `entries`が空でもセクション自体を隠さない — Gmail以外のアカウントは
    /// `matchesCategory(mailbox:account:role:)`が個別の物理メールボックスに
    /// 一致させられない (`\All` special-useを持つIMAPサーバがまず無いため)
    /// ので`entries`に現れないが、「そのアカウントの隠されていない mailbox
    /// すべて」という定義でセクション見出しタップの統合ビュー
    /// (`onSelectUnifiedRole(.all)` → `ThreadQuery.unifiedInboxRequest`/
    /// `MessageQuery.unifiedInboxUnreadCount`の`role == .all`特別扱い) には
    /// ちゃんと含まれる。つまりGmailだけのアカウント構成が無くても
    /// 「すべてのメール」自体は常に有効な見出し — 他カテゴリのように
    /// 「対応する物理メールボックスを持つアカウントが1つも無ければ見出し
    /// ごと消える」動作にはしない。詳細な定義は`docs/design-system.md`の
    /// Task #141 節参照。
    @ViewBuilder
    private func categorySection(for role: MailboxRoleRecord) -> some View {
        let entries = mailboxEntries(for: role)
        if !entries.isEmpty || role == .all {
            let isCollapsed = collapsedCategoryRoles.contains(role.rawValue)
            Section {
                if !isCollapsed {
                    ForEach(entries) { entry in
                        categoryAccountRow(for: entry)
                    }
                }
            } header: {
                CategorySectionHeader(
                    role: role,
                    // Task #126 追加仕様: 削除した最上部「すべての受信トレイ」
                    // 行が使っていた`unifiedInboxUnread`(`MessageQuery
                    // .unifiedInboxUnreadCountObservation`由来、単純な
                    // メールボックス単位の合算とは別の「統合受信トレイ」自身の
                    // 未読数) を、`.inbox`カテゴリの見出しバッジへそのまま
                    // 引き継ぐ — 他のroleは従来どおりメールボックス単位の合算。
                    // Task #141: `.all`は`entries`(Gmailの All Mail のみ) 単独
                    // だと非Gmailアカウント分が漏れるため専用の集計関数を使う
                    // (`unreadCountForAllMailCategory(entries:)`のdoc comment
                    // 参照)。
                    unreadCount: role == .inbox
                        ? unifiedInboxUnread
                        : role == .all
                            ? unreadCountForAllMailCategory(entries: entries)
                            : entries.compactMap(\.mailboxId).reduce(0) { $0 + (unreadByMailboxId[$1] ?? 0) },
                    isCollapsed: isCollapsed,
                    // Task #126 追加仕様: 削除した最上部「すべての受信トレイ」
                    // 行が担っていた選択中ハイライトを、「受信トレイ」セクション
                    // 見出し行自身に移した — `.inbox`は`isUnifiedInboxSelected`
                    // (`onSelectUnified`と対になる状態)、他のroleは既存どおり
                    // `selectedUnifiedRole`との一致で判定する。
                    isSelected: role == .inbox ? isUnifiedInboxSelected : selectedUnifiedRole == role,
                    onSelectUnified: { selectUnifiedView(for: role) },
                    onToggle: { toggleCategoryCollapsed(role) }
                )
                .id("menuSection-role-\(role.rawValue)")
            }
        }
    }

    /// Task #141: 「すべてのメール」セクション見出しの未読バッジ —
    /// 他カテゴリの`entries`ベース集計 (`categorySection(for:)`参照) と
    /// 違い、Gmail以外のアカウントは`mailboxEntries(for: .all)`に現れない
    /// (per-account 展開行を持たない — `matchesCategory`のdoc comment参照)
    /// ので、その分をアカウントの全 mailbox 横断で別途足し込む。Gmail
    /// アカウントは`entries`(All Mail mailboxのみ) に含まれる値をそのまま
    /// 使う (`mailboxesByAccountId`から二重に拾って二重計上しないため)。
    private func unreadCountForAllMailCategory(entries: [MailboxEntry]) -> Int {
        let gmailTotal = entries.compactMap(\.mailboxId).reduce(0) { $0 + (unreadByMailboxId[$1] ?? 0) }
        let nonGmailTotal = environment.accounts
            .filter { $0.kind != .gmail }
            .reduce(0) { total, account in
                let mailboxIds = (mailboxesByAccountId[account.id] ?? []).compactMap(\.id)
                return total + mailboxIds.reduce(0) { $0 + (unreadByMailboxId[$1] ?? 0) }
            }
        return gmailTotal + nonGmailTotal
    }

    /// Task #110: 「受信トレイ」セクション見出しのタップは、統合受信トレイ
    /// トップ行 (`statusSection`の「すべての受信トレイ」、`onSelectUnified`
    /// → `mailSelection = .unifiedInbox`) と全く同じ選択にする — 受信トレイ
    /// 以外のセクション (アーカイブ/送信済み/下書き/迷惑メール/ゴミ箱/
    /// フラグ付き) は元々トップレベルの専用行を持たないため、`onSelectUnifiedRole
    /// (role)` (`mailSelection = .unifiedRole(role)`) をそのまま使う。
    private func selectUnifiedView(for role: MailboxRoleRecord) {
        if role == .inbox {
            onSelectUnified()
        } else {
            onSelectUnifiedRole(role)
        }
    }

    /// role で分類できるカテゴリセクション (受信トレイ/アーカイブ/送信済み
    /// 等) 内、1アカウントぶんの行 — Task #52, 1: Spark を参考に「アカウント
    /// の表示名 + アカウント色の縦罫」を主表示にする (`AccountColorRail`と
    /// 同じ罫線、`ThreadRowView`が1d一覧行で使っているのと同じ組み方)。
    /// フォルダ名 (`mailbox.displayPath`) 自体は表示しない — 同じカテゴリ内で
    /// は「どの役割か」はセクション見出しがすでに示しており、複数アカウントを
    /// 見分けたいだけの場面でフォルダの生パス名 (IMAP実装依存の命名, 例:
    /// "[Gmail]/All Mail") を出すのはノイズという判断。
    ///
    /// Task #126, 3: role で分類できない (`.none`) フォルダ専用の「その他」
    /// セクション (旧`uncategorizedSection`/`categoryMailboxRow(for:)`) は
    /// 廃止した — この行はもう`.none`向けの呼び出し元を持たない。
    private func categoryAccountRow(for entry: MailboxEntry) -> some View {
        let mailboxSelection = MailboxSelection(accountId: entry.account.id, mailboxId: entry.mailboxId)
        let isSelected = selectedMailboxId == entry.mailboxId
        return CategoryAccountRow(
            accountId: entry.account.id,
            mailboxPath: entry.mailbox.path,
            accountDisplayName: entry.account.displayName,
            labelColorKey: entry.account.labelColorKey,
            unreadCount: unreadByMailboxId[entry.mailboxId],
            isSelected: isSelected,
            onTap: { onSelectMailbox(mailboxSelection, entry.account.displayName) }
        )
    }

    /// 全アカウントを横断して`role`のメールボックスを集める — `account`ごとに
    /// 独立して保持している`mailboxesByAccountId`から、この画面のカテゴリ優先
    /// セクションが必要とする形 (どのアカウントの、どのメールボックスか) へ
    /// フラット化する。
    ///
    /// Task #154 (実機報告「ゴミ箱カテゴリに Gmail が2行出る」防御層):
    /// 根治 (`AccountSyncer.upsertMailboxes`) は次回同期以降のDBを正すが、
    /// まだ同期していない既存インストールの残存データ (旧DB) に対しては
    /// このメニュー自体でも同一アカウント内の重複行を1つへ畳む —
    /// `dedupedByAccount(_:)`参照。
    private func mailboxEntries(for role: MailboxRoleRecord) -> [MailboxEntry] {
        environment.accounts.flatMap { account -> [MailboxEntry] in
            let matches = (mailboxesByAccountId[account.id] ?? [])
                .filter { matchesCategory(mailbox: $0, account: account, role: role) }
            return dedupedByAccount(matches).compactMap { mailbox in
                mailbox.id.map { MailboxEntry(account: account, mailbox: mailbox, mailboxId: $0) }
            }
        }
    }

    /// Task #154: collapses `matches` (one account's mailboxes already
    /// filtered to a single category role) down to at most one —
    /// `AccountSyncer.upsertMailboxes`'s root fix means this is normally
    /// already a 0-or-1-element array by the time this runs, but a device
    /// that hasn't resynced since upgrading (or a server situation the root
    /// fix doesn't cover) can still hand this more than one. Prefers a
    /// SPECIAL-USE/IMAP-guaranteed mailbox (`roleIsAuthoritative == true`,
    /// `MailboxRecord.roleIsAuthoritative`'s doc comment) over a name-guessed
    /// one; among equally-authoritative candidates (shouldn't normally
    /// happen), picks the lowest `id` for a deterministic, stable choice
    /// rather than whatever order the observation happened to return.
    private func dedupedByAccount(_ matches: [MailboxRecord]) -> [MailboxRecord] {
        guard let winner = matches.min(by: { lhs, rhs in
            if lhs.roleIsAuthoritative != rhs.roleIsAuthoritative {
                return lhs.roleIsAuthoritative && !rhs.roleIsAuthoritative
            }
            return (lhs.id ?? .max) < (rhs.id ?? .max)
        }) else { return [] }
        return [winner]
    }

    /// Task #52, 2: Gmail は`\Archive`special-useフォルダを持たないため、
    /// 「アーカイブ」カテゴリの実体を Gmail アカウントに限り All Mail
    /// (role`.all`)とする — メニュー表示側 (どのメールボックスを「アーカイブ」
    /// 行として出すか) のマッピング。対になる`OtegamiStore.MailboxRoleRecord
    /// .gmailArchiveQueryRole`/`GmailArchiveFilter`は、その行を実際に開いた
    /// 時のスレッド一覧側の定義 (`docs/design-system.md`記載の Gmail 検索式
    /// と等価な集合、単純な All Mail 全件ではない) を担う — 役割が違うので
    /// 別々に実装している。
    ///
    /// Task #141: `MailboxRoleRecord.categoryOrder`が`.all`(「すべてのメール」)
    /// を独立カテゴリとして持つようになった後も、この関数自体は無変更 ——
    /// `role == .all`で呼ばれた場合、`mailbox.role == role`の等価チェックが
    /// そのまま Gmail の All Mail メールボックスに一致する (`.all == .all`)。
    /// 結果として Gmail の All Mail は「アーカイブ」と「すべてのメール」の
    /// 両カテゴリの展開行に重複して現れる — Task #52, 2 時点で避けていた
    /// 重複をこのタスクでは許容する判断 (`docs/design-system.md`参照)。
    /// 非Gmailアカウントは`\All` special-useを持つことがまず無いため、
    /// この等価チェックだけでは「すべてのメール」の展開行に現れない ——
    /// それは仕様どおりで、`categorySection(for:)`のdoc comment/
    /// `docs/design-system.md`が記録する「非Gmailは統合ビュー (セクション
    /// 見出しタップ) からのみ到達— 個別アカウント行は持たない」という
    /// 判断による。
    private func matchesCategory(mailbox: MailboxRecord, account: AccountRecord, role: MailboxRoleRecord) -> Bool {
        if mailbox.role == role { return true }
        if role == .archive, mailbox.role == .all, account.kind == .gmail { return true }
        return false
    }

    /// `toggleAccountCollapsed(_:)` の doc comment 参照 (アコーディオン動作)。
    private func toggleCategoryCollapsed(_ role: MailboxRoleRecord) {
        let collapsing = !collapsedCategoryRoles.contains(role.rawValue)
        withAnimation(.default) {
            if collapsing {
                collapsedCategoryRoles.insert(role.rawValue)
            } else {
                collapsedCategoryRoles = Set(categoryOrder.map(\.rawValue)).subtracting([role.rawValue])
                collapsedAccountIds = Set(environment.accounts.map(\.id))
            }
        }
        FolderCategoryCollapseStore.replaceAll(collapsedRoleRawValues: collapsedCategoryRoles)
        FolderSectionCollapseStore.replaceAll(collapsedAccountIds: collapsedAccountIds)
        if !collapsing {
            // 展開に気づけるよう見出しを上端へ (`menuScrollTarget`参照)。
            menuScrollTarget = "menuSection-role-\(role.rawValue)"
        }
    }

    /// Mirrors `SidebarView.mailboxRow(for:in:)`'s split (see its own doc
    /// comment/`docs/ci.md`): the `ForEach` closure stays a single named
    /// function call, everything else lives in `FolderMailboxRow`.
    @ViewBuilder
    private func folderMailboxRow(for mailbox: MailboxRecord, in account: AccountRecord) -> some View {
        if let mailboxId = mailbox.id {
            let mailboxSelection = MailboxSelection(accountId: account.id, mailboxId: mailboxId)
            let isSelected = selectedMailboxId == mailboxId
            FolderMailboxRow(
                accountId: account.id,
                mailbox: mailbox,
                unreadCount: unreadByMailboxId[mailboxId],
                isSelected: isSelected,
                onTap: { onSelectMailbox(mailboxSelection, mailbox.displayPath) }
            )
        }
    }

    private func observeMailboxes(accountId: String) async {
        // メールボックス単位の非表示: `includeHidden: false` keeps a hidden
        // mailbox out of the hamburger tree entirely — see
        // `MailboxQuery.request(accountId:includeHidden:)`'s doc comment.
        let observation = MailboxQuery.observation(accountId: accountId, includeHidden: false)
        do {
            for try await mailboxes in observation.values(in: environment.database.dbWriter) {
                mailboxesByAccountId[accountId] = mailboxes
            }
        } catch {
            // A failing observation for one account shouldn't take down the sheet.
        }
    }

    private func observeUnreadCounts(accountId: String) async {
        let observation = MessageQuery.unreadCountsObservation(accountId: accountId)
        do {
            for try await counts in observation.values(in: environment.database.dbWriter) {
                for (mailboxId, count) in counts {
                    unreadByMailboxId[mailboxId] = count
                }
                let staleMailboxIds = (mailboxesByAccountId[accountId] ?? [])
                    .compactMap(\.id)
                    .filter { counts[$0] == nil }
                for mailboxId in staleMailboxIds {
                    unreadByMailboxId.removeValue(forKey: mailboxId)
                }
            }
        } catch {
            // A failing observation just stops that account's badges from updating.
        }
    }

    private func observeOutbox() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = OutboxQuery.observation(accountIds: accountIds)
        do {
            for try await pending in observation.values(in: environment.database.dbWriter) {
                outboxCount = pending.count
            }
        } catch {
            // A failing observation just stops the badge from updating.
        }
    }

    private func observeDraftCount() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = DraftQuery.unifiedObservation(accountIds: accountIds)
        do {
            for try await drafts in observation.values(in: environment.database.dbWriter) {
                draftCount = drafts.count
            }
        } catch {
            // A failing observation just stops the badge from updating.
        }
    }

    private func observeFailedOpCount() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = OpQueueQuery.failedOpsObservation(accountIds: accountIds, minAttempts: OpQueueProcessor.maxAttempts)
        do {
            for try await ops in observation.values(in: environment.database.dbWriter) {
                failedOpCount = ops.count
            }
        } catch {
            // A failing observation just stops the badge from updating.
        }
    }

    private func observeMailboxSyncFailureCount() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = MailboxQuery.syncFailuresObservation(accountIds: accountIds)
        do {
            for try await mailboxes in observation.values(in: environment.database.dbWriter) {
                mailboxSyncFailureCount = mailboxes.count
            }
        } catch {
            // A failing observation just stops the badge from updating.
        }
    }

    private func observeUnifiedInboxUnreadCount() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = MessageQuery.unifiedInboxUnreadCountObservation(accountIds: accountIds)
        do {
            for try await count in observation.values(in: environment.database.dbWriter) {
                unifiedInboxUnread = count
            }
        } catch {
            // A failing observation just stops the badge from updating.
        }
    }
}

/// K (実機フィードバック第3弾): persists which accounts' mailbox trees are
/// collapsed — a plain `UserDefaults` array under one key (not a value per
/// account id, since the set of collapsed accounts is small and read/
/// written as a whole every time anyway). Account names are dynamic user
/// data, never localized strings, so unlike this app's `*SettingsStore`
/// types this one has no `docs/localization.md` concerns.
enum FolderSectionCollapseStore {
    static let collapsedAccountIdsKey = "folderSheet.collapsedAccountIds"

    static var collapsedAccountIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedAccountIdsKey) ?? [])
    }

    static func setCollapsed(_ collapsed: Bool, accountId: String) {
        var ids = collapsedAccountIds
        if collapsed {
            ids.insert(accountId)
        } else {
            ids.remove(accountId)
        }
        UserDefaults.standard.set(Array(ids), forKey: collapsedAccountIdsKey)
    }

    /// Task #73: ドロワーを開いた瞬間の一括リセット専用 — `setCollapsed(_:accountId:)`
    /// を1件ずつ呼ぶ (読み直し→書き直しをアカウント数ぶん繰り返す) 代わりに、
    /// 計算済みの集合をまとめて書く。
    static func replaceAll(collapsedAccountIds: Set<String>) {
        UserDefaults.standard.set(Array(collapsedAccountIds), forKey: collapsedAccountIdsKey)
    }
}

/// K: one account's tappable `Section` header inside `FolderListSheet` —
/// the account's display name, its aggregate unread badge (visible whether
/// expanded or collapsed — "折りたたみ中も見えること"), and a chevron whose
/// rotation communicates the current state (SwiftUI's own `DisclosureGroup`
/// convention, reproduced here rather than using `DisclosureGroup` itself
/// since that type doesn't let this app style the header as a plain
/// `Section`-header row alongside the rest of `SidebarView`/`FolderListSheet`'s
/// existing row styling).
private struct AccountSectionHeader: View {
    let accountId: String
    /// 実機フィードバック第3弾 (2026-07-29「ハンバーガーメニューでも
    /// アカウント名の横に色をつけてほしい」): カテゴリ内アカウント行
    /// (`CategoryAccountRow`) と同じ `AccountColorRail` を名前の左に出す。
    let labelColorKey: String?
    let title: String
    let unreadCount: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                AccountColorRail(accountId: accountId, labelColorKey: labelColorKey)
                Text(verbatim: title)
                Spacer()
                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(OtegamiFont.badge())
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Task #126, 2: これは`Section`の`header:`(List行そのものではない)
        // なので`.listRowInsets`は効かない — `.frame(minHeight: 44)`だけ、
        // タップターゲットの下限保証として付けている (`otegamiMenuRowChrome()`
        // のdoc comment参照)。実機フィードバック第2弾でこちらも 44→36 に
        // 圧縮 (セクション見出しは繰り返し行より一段だけ背を残す)。
        .frame(minHeight: 36)
        .accessibilityIdentifier("folderSheet.account.\(accountId).header")
        // VoiceOver: the chevron's rotation alone communicates nothing to
        // VoiceOver, so the collapsed/expanded state is spelled out in the
        // trait/label instead — standard `DisclosureGroup` accessibility
        // behavior, reproduced here since this is a hand-rolled substitute.
        .accessibilityAddTraits(isCollapsed ? [] : .isSelected)
        .accessibilityValue(isCollapsed ? "折りたたみ" : "展開")
    }
}

/// Task #52, 1: one account's row inside a role-based category section
/// (`FolderListSheet.categoryAccountRow(for:)`) — `AccountColorRail` +
/// the account's display name, mirroring Spark's "アーカイブ" category
/// screenshot (色付きバー + アカウント名の並び, `docs/design-system.md`参照)
/// rather than a mailbox path. Split out of the `ForEach` closure for the
/// same CI type-check reason every other row-shaped closure in this file
/// already is (`docs/ci.md`).
private struct CategoryAccountRow: View {
    let accountId: String
    /// アクセシビリティ識別子の一意性のためだけの値 — 同じアカウントが
    /// 複数のカテゴリセクション (例: Gmail が「受信トレイ」と「アーカイブ」
    /// 両方) に現れうるので、`accountId`単独では識別子が重複する。行の
    /// マッピング元メールボックスの`path`まで含めれば一意になる
    /// (`FolderMailboxRow`の`folderSheet.mailbox.<accountId>.<path>`と同じ
    /// 発想)。
    let mailboxPath: String
    let accountDisplayName: String
    /// D「アカウントのラベル色を変更可能に」: `AccountRecord.labelColorKey`,
    /// forwarded to `AccountColorRail` as-is (`nil` = automatic FNV-1a
    /// assignment) — same as `ThreadRowView`'s own use of this field.
    let labelColorKey: String?
    let unreadCount: Int?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 0) {
                AccountColorRail(accountId: accountId, labelColorKey: labelColorKey)
                HStack {
                    // `AccountFilterChip.label`のdoc comment参照: 表示名は
                    // `LocalizedStringKey`経由に流すと(表示名がメールアドレス
                    // そのものの場合に) SwiftUIがMarkdownの自動リンクとして
                    // 解釈し、タップで`mailto:`が開く実機バグを踏む —
                    // `Text(verbatim:)`で素通しする。
                    Text(verbatim: accountDisplayName)
                    Spacer()
                    if let unreadCount, unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(OtegamiFont.badge())
                    }
                }
                .padding(.leading, OtegamiSpacing.sm)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .otegamiMenuRowChrome()
        .listRowBackground(isSelected ? OtegamiColor.paleBase : nil)
        .accessibilityIdentifier("folderSheet.category.account.\(accountId).\(mailboxPath)")
    }
}

/// One mailbox row inside `FolderListSheet` — see `SidebarView.MailboxRow`'s
/// doc comment for why this is split out of the `ForEach` closure at all
/// (same CI type-check rationale, independently re-applied to this file).
///
/// Task #126, 3: この行はもうアカウント優先モードの
/// `folderMailboxRow(for:in:)`だけから使われる (カテゴリ優先モードの「その他」
/// セクション向けだった旧`categoryMailboxRow(for:)`は削除済み) — アカウント
/// 優先モードでは呼び出し元のアカウント自身がすでにSection見出しなので、
/// 行の中に別アカウント名を併記する`accountLabelText`パラメータは常に`nil`
/// にしかならなくなった。使われなくなったフィールドと表示分岐を削除した。
private struct FolderMailboxRow: View {
    let accountId: String
    let mailbox: MailboxRecord
    let unreadCount: Int?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Label(mailbox.displayPath, systemImage: icon(for: mailbox.role))
                Spacer()
                if let unreadCount, unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(OtegamiFont.badge())
                        .accessibilityIdentifier("folderSheet.mailbox.\(accountId).\(mailbox.path).unreadBadge")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .otegamiMenuRowChrome()
        .listRowBackground(isSelected ? OtegamiColor.paleBase : nil)
        .accessibilityIdentifier("folderSheet.mailbox.\(accountId).\(mailbox.path)")
    }

    private func icon(for role: MailboxRoleRecord) -> String {
        switch role {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .trash: "trash"
        case .junk: "exclamationmark.octagon"
        case .archive: "archivebox"
        case .flagged: "flag"
        case .all: "envelope.badge.fill"
        case .none: "folder"
        }
    }
}

// MARK: - 画面構造改修バッチ (Task #33, 3): カテゴリ優先グルーピング

/// `FolderSectionCollapseStore`のrole版 — カテゴリ優先モードのセクション
/// (role単位)の折りたたみ状態を、アカウント優先モードのそれとは独立して
/// 永続化する(`FolderListSheet.collapsedCategoryRoles`のdoc comment参照)。
enum FolderCategoryCollapseStore {
    static let collapsedRolesKey = "folderSheet.collapsedCategoryRoles"

    static var collapsedRoleRawValues: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedRolesKey) ?? [])
    }

    static func setCollapsed(_ collapsed: Bool, role: MailboxRoleRecord) {
        var values = collapsedRoleRawValues
        if collapsed {
            values.insert(role.rawValue)
        } else {
            values.remove(role.rawValue)
        }
        UserDefaults.standard.set(Array(values), forKey: collapsedRolesKey)
    }

    /// Task #73: `FolderSectionCollapseStore.replaceAll(collapsedAccountIds:)`
    /// と同じ理由の一括版。
    static func replaceAll(collapsedRoleRawValues: Set<String>) {
        UserDefaults.standard.set(Array(collapsedRoleRawValues), forKey: collapsedRolesKey)
    }
}

/// カテゴリ優先モードの1行ぶん — どのアカウントの、どのメールボックスか
/// (`FolderListSheet.mailboxEntries(for:)`が`mailboxesByAccountId`から
/// フラット化して作る)。`mailboxId`を`Identifiable`の`id`に使う —
/// `MailboxRecord.id`自体は`Int64?`(未保存の場合`nil`)だが、この画面が
/// 扱うのは常にDBから読み込み済みの(=idを持つ)行なので、`mailboxEntries(for:)`
/// 側で`nil`を弾いてから渡す。
private struct MailboxEntry: Identifiable {
    let account: AccountRecord
    let mailbox: MailboxRecord
    let mailboxId: Int64

    var id: Int64 { mailboxId }
}

/// `AccountSectionHeader`のrole版 — カテゴリ優先モードの1セクション見出し。
/// 「折りたたみ中も見えること」の要件は`AccountSectionHeader`と同じ理由で
/// ここでも踏襲。
///
/// Task #110 (ハンバーガーメニューの挙動変更): 見出し本体は折りたたみ開閉
/// ではなく統合ビュー選択の`Button`(`onSelectUnified`) になり、折りたたみ
/// 開閉は右端の独立したシェブロン`Button`(`CategoryDisclosureChevron`)だけが
/// 担う (タップターゲットを44pt確保)。Task #126, 3で「その他」
/// (`.none`、統合ビュー概念自体が無いセクション) を廃止したことで、この
/// ビューの呼び出し元は常に`categoryOrder`のroleだけになった — 元は
/// `onSelectUnified`が`nil`許容 (`.none`向け、見出し全体が折りたたみ開閉の
/// 単一`Button`になる分岐) だったが、その分岐が到達不能になったため
/// `(() -> Void)?`を非オプショナルに単純化した。
///
/// Task #126 追加仕様: 削除した最上部「すべての受信トレイ」行のハイライト
/// (`isUnifiedInboxSelected`)/`selectedUnifiedRole`一致によるハイライトを
/// この見出し行が引き継ぐ — `isSelected`が`true`のとき、他の選択中の行
/// (`CategoryAccountRow`/`FolderMailboxRow`等) と同じ`OtegamiColor.paleBase`
/// を背景に敷く。この見出しは`Section`の`header:`(`List`の行そのものでは
/// ない) なので`.listRowBackground`は効かない — 他の行が使っている
/// `.listRowBackground`ではなく、素の`.background`をこの`HStack`自身に
/// 直接敷く。
private struct CategorySectionHeader: View {
    let role: MailboxRoleRecord
    let unreadCount: Int
    let isCollapsed: Bool
    let isSelected: Bool
    let onSelectUnified: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelectUnified) {
                HStack {
                    Label(role.categoryDisplayName, systemImage: role.categorySystemImage)
                    Spacer()
                    if unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(OtegamiFont.badge())
                    }
                }
                .contentShape(Rectangle())
            }
            // 実機フィードバック第3弾 (2026-07-29「たまにシェブロンを
            // タップしても反応しない」): 同じ見出し行に2つの `.plain`
            // ボタンが並ぶと List のタップ判定が競合して片方が落ちる
            // ことがある既知の SwiftUI 挙動 — 複数ボタン行の定石どおり
            // `.borderless` に変更 (シェブロン側も同様)。
            .buttonStyle(.borderless)
            // Task #126, 2: `AccountSectionHeader`と同じ理由 —
            // `Section`の`header:`なので`.listRowInsets`は効かず、
            // `.frame(minHeight:)`だけタップターゲットの下限保証として
            // 付ける。実機フィードバック第2弾で 44→36 に圧縮。
            .frame(minHeight: 36)
            .accessibilityIdentifier("folderSheet.category.\(role.rawValue).header")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            CategoryDisclosureChevron(role: role, isCollapsed: isCollapsed, onToggle: onToggle)
        }
        .background(isSelected ? OtegamiColor.paleBase : Color.clear)
    }
}

/// Task #110: `CategorySectionHeader`の折りたたみ開閉専用シェブロン —
/// 見出し行本体が統合ビュー選択に変わったため、開閉操作をここへ切り出した。
/// SF Symbols のグリフ自体は小さいが、タップターゲットは HIG の最小
/// 44×44pt を`.frame(minWidth:minHeight:)`で確保する (ユーザー指示
/// 「シェブロンのタップターゲットは十分広く」)。折りたたみ状態の
/// アクセシビリティ表現 (`.isSelected`トレイト＋`.accessibilityValue`) も、
/// 折りたたみ開閉の実体がここへ移ったことに合わせてここへ移した
/// (旧`CategorySectionHeader`本体が持っていたのと同じ表現)。
private struct CategoryDisclosureChevron: View {
    let role: MailboxRoleRecord
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: "chevron.right")
                .font(.caption)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("folderSheet.category.\(role.rawValue).chevron")
        .accessibilityLabel(Text(role.categoryDisplayName))
        .accessibilityAddTraits(isCollapsed ? [] : .isSelected)
        .accessibilityValue(isCollapsed ? "折りたたみ" : "展開")
    }
}

/// Task #126, 2 (ハンバーガーメニュー各行の縦paddingを詰める) → 実機
/// フィードバック第2弾 (2026-07-29「各行の高さをもっと短くして」) で
/// さらに圧縮: `minHeight` 44→32、縦insets `OtegamiSpacing.sm`(8pt)→
/// `OtegamiSpacing.xs`(4pt)。HIG の 44pt タップターゲットを見た目の行高
/// が下回るが、これはユーザーの明示指示によるトレードオフ (行自体が
/// リスト幅いっぱいのタップ領域を持つため、横方向の当てやすさで実用上
/// 補われる)。フォントサイズは変えていない。水平方向は
/// `OtegamiSpacing.lg`(16pt) のまま。`private`なので同一ファイル内の型
/// だけが使う。
private extension View {
    func otegamiMenuRowChrome() -> some View {
        self
            .frame(minHeight: 32)
            .listRowInsets(EdgeInsets(
                top: OtegamiSpacing.xs, leading: OtegamiSpacing.lg,
                bottom: OtegamiSpacing.xs, trailing: OtegamiSpacing.lg
            ))
    }
}
