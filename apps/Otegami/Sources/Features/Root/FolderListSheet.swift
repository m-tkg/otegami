import SwiftUI
import GRDB
import OtegamiStore
import SyncEngine

/// iOS-only (1a): "フォルダ切替はナビタイトルのタップでシート表示" — the sheet
/// `MailTabView` presents when its tappable title button is tapped. Content
/// mirrors what `SidebarView` (macOS's permanently-visible left column)
/// shows — unified inbox row, outbox/drafts/sync-error banners, each
/// account's mailbox tree — per this task's brief: "現在のサイドバー相当の
/// 内容...をこのシートに集約する". Deliberately a *separate* type from
/// `SidebarView` rather than a shared extraction: this view owns its own
/// `ValueObservation`s (mailboxes, unread counts, outbox/draft/error
/// counts) with the same shape as `SidebarView`'s, but the two are
/// presented completely differently (an always-visible `NavigationSplitView`
/// column vs. a `.sheet`) and `SidebarView` is macOS-only from here on —
/// keeping them independent avoids coupling two screens that no longer
/// share a rendering context, at the cost of the observation logic living
/// in two places. See `docs/design-system.md` for the tradeoff this task
/// recorded.
///
/// Rows that would need a *second* sheet (送信待ち/下書き/同期エラー) don't
/// present one directly from here — this view is itself already a sheet,
/// and a sheet-presented-from-a-sheet is a confirmed-broken nesting depth
/// in this app (`AccountsListContent`'s doc comment on why `AccountEditView`
/// is a `NavigationLink` push, not a nested sheet). Each row instead calls
/// an `onOpen*` closure that asks `MailTabView` (the common ancestor, and
/// itself not inside any sheet) to present that sheet *after* this one
/// finishes dismissing — see `MailTabView`'s `handleFolderSheetDismiss()`.
struct FolderListSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let selectedMailboxId: Int64?
    let isUnifiedInboxSelected: Bool
    var onSelectUnified: () -> Void
    var onSelectMailbox: (MailboxSelection, String) -> Void
    var onOpenOutbox: () -> Void
    var onOpenDrafts: () -> Void
    var onOpenFailedOps: () -> Void
    var onOpenMailboxSyncFailures: () -> Void
    var onAddAccount: () -> Void

    @State private var mailboxesByAccountId: [String: [MailboxRecord]] = [:]
    @State private var outboxCount = 0
    @State private var draftCount = 0
    @State private var failedOpCount = 0
    @State private var mailboxSyncFailureCount = 0
    @State private var unreadByMailboxId: [Int64: Int] = [:]
    @State private var unifiedInboxUnread = 0

    var body: some View {
        NavigationStack {
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
                    ForEach(environment.accounts) { account in
                        Section(account.displayName) {
                            ForEach(mailboxesByAccountId[account.id] ?? []) { mailbox in
                                folderMailboxRow(for: mailbox, in: account)
                            }
                        }
                        .task(id: account.id) { await observeMailboxes(accountId: account.id) }
                        .task(id: account.id) { await observeUnreadCounts(accountId: account.id) }
                    }
                }
            }
            .accessibilityIdentifier("folderSheet.list")
            .navigationTitle("フォルダ")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                        .accessibilityIdentifier("folderSheet.closeButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onAddAccount()
                    } label: {
                        Label("アカウントを追加", systemImage: "plus")
                    }
                    .accessibilityIdentifier("folderSheet.addAccountToolbarButton")
                }
            }
        }
        .accessibilityIdentifier("folderSheet.sheet")
        .task(id: environment.accounts.map(\.id)) { await observeOutbox() }
        .task(id: environment.accounts.map(\.id)) { await observeDraftCount() }
        .task(id: environment.accounts.map(\.id)) { await observeFailedOpCount() }
        .task(id: environment.accounts.map(\.id)) { await observeMailboxSyncFailureCount() }
        .task(id: environment.accounts.map(\.id)) { await observeUnifiedInboxUnreadCount() }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            Button {
                onSelectUnified()
            } label: {
                HStack {
                    Label("すべての受信トレイ", systemImage: "tray.2")
                    Spacer()
                    if unifiedInboxUnread > 0 {
                        Text("\(unifiedInboxUnread)")
                            .font(OtegamiFont.badge())
                            .accessibilityIdentifier("folderSheet.unifiedInbox.unreadBadge")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(isUnifiedInboxSelected ? OtegamiColor.paleBase : nil)
            .accessibilityIdentifier("folderSheet.unifiedInbox")

            if outboxCount > 0 {
                Button {
                    onOpenOutbox()
                } label: {
                    Label("送信待ち (\(outboxCount))", systemImage: "tray.and.arrow.up")
                }
                .accessibilityIdentifier("folderSheet.outbox")
            }
            if draftCount > 0 {
                Button {
                    onOpenDrafts()
                } label: {
                    Label("下書き (\(draftCount))", systemImage: "doc")
                }
                .accessibilityIdentifier("folderSheet.drafts")
            }
            if failedOpCount > 0 {
                Button {
                    onOpenFailedOps()
                } label: {
                    Label("同期エラー (\(failedOpCount))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(OtegamiColor.destructive)
                }
                .accessibilityIdentifier("folderSheet.failedOps")
            }
            if mailboxSyncFailureCount > 0 {
                Button {
                    onOpenMailboxSyncFailures()
                } label: {
                    Label("メールボックス同期エラー (\(mailboxSyncFailureCount))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(OtegamiColor.destructive)
                }
                .accessibilityIdentifier("folderSheet.mailboxSyncFailures")
            }
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
        let observation = MailboxQuery.observation(accountId: accountId)
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

/// One mailbox row inside `FolderListSheet` — see `SidebarView.MailboxRow`'s
/// doc comment for why this is split out of the `ForEach` closure at all
/// (same CI type-check rationale, independently re-applied to this file).
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
