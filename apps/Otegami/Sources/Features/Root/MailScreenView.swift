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

    var body: some View {
        HamburgerMenuContainer(isOpen: $isMenuOpen) {
            menuContent
        } content: {
            mailNavigationStack
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
        }
    }

    private var mailNavigationStack: some View {
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
        .tint(OtegamiColor.accent)
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !isSelecting {
            ToolbarItem(placement: .navigation) {
                hamburgerButton
            }
            ToolbarItem(placement: .principal) {
                Text(selectionTitle)
                    .font(OtegamiFont.headline())
                    .foregroundStyle(OtegamiColor.ink)
                    .accessibilityIdentifier("mail.title")
            }
            ToolbarItemGroup(placement: .confirmationAction) {
                unreadOnlyToggleButton

                Button(action: onCompose) {
                    Label("作成", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("mail.composeButton")
                .disabled(environment.accounts.isEmpty)
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
    private var floatingSearchButton: some View {
        Button {
            openSearch()
        } label: {
            Label("検索", systemImage: "magnifyingglass")
                .labelStyle(.iconOnly)
                .font(OtegamiFont.body())
                .padding(OtegamiSpacing.md + OtegamiSpacing.xs)
                .background(OtegamiColor.surface, in: Circle())
                .overlay(Circle().stroke(OtegamiColor.dividerSubtle, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.leading, OtegamiSpacing.lg)
        .padding(.bottom, OtegamiSpacing.lg)
        .accessibilityIdentifier("mail.searchButton")
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
