import SwiftUI
import OtegamiStore

/// iOS's "メール" tab (1a): タイトル「すべての受信」(tappable → `FolderListSheet`)
/// → `AccountFilterChipRow` (only meaningful while the unified inbox is
/// selected) → `MessageListView`. Owns the one piece of navigation state
/// `MessageListView` itself no longer does on iOS (`navigationTitle`/
/// `.searchable` moved out — see that view's doc comment): which mailbox is
/// selected, which account the filter chips narrow to, and which thread (if
/// any) is pushed.
struct MailTabView: View {
    @Environment(AppEnvironment.self) private var environment
    var onCompose: () -> Void
    var onOpenDraft: (Int64) -> Void
    var onOpenServerDraft: (Int64) -> Void
    var onReply: (Int64, Bool, Bool) -> Void
    /// C7: reopens the Composer with a just-cancelled pending send's fields
    /// — see `handleCancelPendingSend()`.
    var onOpenCancelledSend: (PendingSendDraftSnapshot) -> Void

    @State private var mailSelection: SidebarSelection = .unifiedInbox
    @State private var accountFilter: String?
    @State private var selectionTitle = "すべての受信"
    @State private var selectedThreadId: Int64?
    @State private var isSelecting = false

    @State private var showingFolderSheet = false
    @State private var accountEntryRoute: AccountEntryRoute?
    @State private var showingOutbox = false
    @State private var showingDrafts = false
    @State private var showingFailedOps = false
    @State private var showingMailboxSyncFailures = false
    /// What to present once `FolderListSheet` finishes dismissing — see
    /// `FolderListSheet`'s doc comment on why its own outbox/drafts/error
    /// rows can't present a second sheet directly (sheet-from-a-sheet is a
    /// confirmed-broken nesting depth in this app).
    @State private var pendingPostFolderAction: PostFolderSheetAction?

    private enum PostFolderSheetAction {
        case outbox, drafts, failedOps, mailboxSyncFailures, addAccount
    }

    var body: some View {
        NavigationStack {
            content
                .toolbar { toolbarContent }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .navigationDestination(item: $selectedThreadId) { threadId in
                    ThreadDetailView(threadId: threadId, onReply: onReply)
                }
                .sheet(isPresented: $showingFolderSheet, onDismiss: handleFolderSheetDismiss) {
                    folderSheet
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
            ToolbarItem(placement: .principal) {
                folderTitleButton
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: onCompose) {
                    Label("作成", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("mail.composeButton")
                .disabled(environment.accounts.isEmpty)
            }
        }
    }

    /// The tappable nav title (1a: "フォルダ切替はナビタイトルのタップでシート
    /// 表示") — a `Button` standing in for the native (non-interactive)
    /// large title, styled to still read as a title (headline weight) with
    /// a trailing chevron hinting it opens something, the same convention
    /// Apple's own Mail app uses for its mailbox-picker title.
    private var folderTitleButton: some View {
        Button {
            showingFolderSheet = true
        } label: {
            HStack(spacing: OtegamiSpacing.xs) {
                Text(selectionTitle)
                    .font(OtegamiFont.headline())
                    .foregroundStyle(OtegamiColor.ink)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(OtegamiColor.inkSecondary)
            }
        }
        .accessibilityIdentifier("mail.folderTitleButton")
    }

    private var folderSheet: some View {
        FolderListSheet(
            selectedMailboxId: selectedMailboxId,
            isUnifiedInboxSelected: isUnifiedInboxSelected,
            onSelectUnified: selectUnifiedInbox,
            onSelectMailbox: selectMailbox,
            onOpenOutbox: { requestPostFolderAction(.outbox) },
            onOpenDrafts: { requestPostFolderAction(.drafts) },
            onOpenFailedOps: { requestPostFolderAction(.failedOps) },
            onOpenMailboxSyncFailures: { requestPostFolderAction(.mailboxSyncFailures) },
            onAddAccount: { requestPostFolderAction(.addAccount) }
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
        showingFolderSheet = false
    }

    private func selectMailbox(_ mailboxSelection: MailboxSelection, _ displayName: String) {
        mailSelection = .mailbox(mailboxSelection)
        selectionTitle = displayName
        accountFilter = nil
        showingFolderSheet = false
    }

    private func presentAddAccount() {
        accountEntryRoute = .typeSelection
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

    private func requestPostFolderAction(_ action: PostFolderSheetAction) {
        pendingPostFolderAction = action
        showingFolderSheet = false
    }

    /// `FolderListSheet`'s `.sheet(isPresented:onDismiss:)` callback — runs
    /// once the folder sheet has fully dismissed, so whichever sheet a row
    /// tap requested (`requestPostFolderAction(_:)`) presents at a sibling
    /// level instead of nested inside the just-closed one.
    private func handleFolderSheetDismiss() {
        switch pendingPostFolderAction {
        case .outbox: showingOutbox = true
        case .drafts: showingDrafts = true
        case .failedOps: showingFailedOps = true
        case .mailboxSyncFailures: showingMailboxSyncFailures = true
        case .addAccount: accountEntryRoute = .typeSelection
        case nil: break
        }
        pendingPostFolderAction = nil
    }
}
