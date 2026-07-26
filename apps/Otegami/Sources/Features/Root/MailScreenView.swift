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
/// 常に左上のハンバーガーアイコンから。検索はヘッダの虫眼鏡ボタンから
/// `SearchScreenView` をシート表示する。
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
    @State private var selectionTitle = "すべての受信"
    @State private var selectedThreadId: Int64?
    @State private var isSelecting = false

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

    var body: some View {
        HamburgerMenuContainer(isOpen: $isMenuOpen) {
            menuContent
        } content: {
            mailNavigationStack
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
                    ThreadDetailView(
                        threadId: threadId, onReply: onReply, onForward: onForward,
                        onSearchFromSender: { query in openSearch(presetQuery: query) }
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
                AccountFilterChipRow(accounts: environment.accounts, selectedAccountId: $accountFilter, onAddAccount: presentAddAccount)
            }
            if environment.accounts.isEmpty {
                emptyState
            } else {
                MessageListView(
                    selection: mailSelection,
                    unifiedInboxAccountFilter: accountFilter,
                    selectedThreadId: $selectedThreadId,
                    onSelectionModeChanged: { isSelecting = $0 }
                )
            }
        }
        .background(OtegamiColor.background)
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
                Button { openSearch() } label: {
                    Label("検索", systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier("mail.searchButton")

                Button(action: onCompose) {
                    Label("作成", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("mail.composeButton")
                .disabled(environment.accounts.isEmpty)
            }
        }
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
            onSelectUnified: selectUnifiedInbox,
            onSelectMailbox: selectMailbox,
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

    private func selectUnifiedInbox() {
        mailSelection = .unifiedInbox
        selectionTitle = "すべての受信"
        accountFilter = nil
        isMenuOpen = false
    }

    private func selectMailbox(_ mailboxSelection: MailboxSelection, _ displayName: String) {
        mailSelection = .mailbox(mailboxSelection)
        selectionTitle = displayName
        accountFilter = nil
        isMenuOpen = false
    }

    private func presentAddAccount() {
        accountEntryRoute = .typeSelection
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
