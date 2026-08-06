import SwiftUI
import OtegamiStore

/// Empty-account content kept outside `SidebarView`'s `List` expression so
/// its three-closure `ContentUnavailableView` is type-checked independently.
struct SidebarEmptyAccountsView: View {
    let onAddAccount: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("アカウントがありません", systemImage: "envelope.badge")
        } description: {
            Text("メールアカウントを追加してください。")
        } actions: {
            Button("アカウントを追加", action: onAddAccount)
                .accessibilityIdentifier("sidebar.addAccountButton")
        }
    }
}

/// iOS-only unified-inbox row. macOS uses its inbox category header as the
/// equivalent selection entry, so `SidebarView` conditionally inserts this
/// view only on iOS.
struct SidebarUnifiedInboxRow: View {
    let isSelected: Bool
    let unreadCount: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Label("すべての受信トレイ", systemImage: "tray.2")
                Spacer()
                if unreadCount > 0 {
                    UnreadCountBadge(count: unreadCount)
                        .accessibilityIdentifier("sidebar.unifiedInbox.unreadBadge")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? OtegamiColor.paleBase : nil)
        .accessibilityIdentifier("sidebar.unifiedInbox")
    }
}

/// One conditional status destination row (outbox, drafts, or a failure
/// list). The caller still controls whether the row exists and owns the
/// presentation state; this type only isolates the button expression.
struct SidebarStatusRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let accessibilityIdentifier: String
    let isError: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            if isError {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.orange)
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Sidebar toolbar buttons, extracted as `ToolbarContent` to keep their
/// nested labels and modifiers out of `SidebarView.body`.
struct SidebarToolbarContent: ToolbarContent {
    let isComposeDisabled: Bool
    let onCompose: () -> Void
    let onAddAccount: () -> Void
    let onOpenSettings: () -> Void

    var body: some ToolbarContent {
        ToolbarItem {
            Button(action: onCompose) {
                Label("作成", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("sidebar.composeButton")
            .disabled(isComposeDisabled)
        }
        ToolbarItem {
            Button(action: onAddAccount) {
                Label("アカウントを追加", systemImage: "plus")
            }
            .accessibilityIdentifier("sidebar.addAccountToolbarButton")
        }
        ToolbarItem {
            Button(action: onOpenSettings) {
                Label("設定", systemImage: "gearshape")
            }
            .accessibilityIdentifier("sidebar.settingsButton")
        }
    }
}

/// Preserves the original sheet modifier order while moving the generic
/// presentation chain out of `SidebarView.body`.
struct SidebarSheetPresentationModifier: ViewModifier {
    @Binding var accountEntryRoute: AccountEntryRoute?
    @Binding var showingSettings: Bool
    @Binding var showingOutbox: Bool
    @Binding var showingDrafts: Bool
    @Binding var showingFailedOps: Bool
    let onOpenDraft: (Int64) -> Void
    let onOpenServerDraft: (Int64) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $accountEntryRoute) { route in
                accountEntryDestination(for: route, binding: $accountEntryRoute)
            }
            .sheet(isPresented: $showingSettings) {
                AccountsSettingsView()
            }
            .sheet(isPresented: $showingOutbox) {
                OutboxView()
            }
            .sheet(isPresented: $showingDrafts) {
                DraftsView(onOpenDraft: onOpenDraft, onOpenServerDraft: onOpenServerDraft)
            }
            .sheet(isPresented: $showingFailedOps) {
                FailedOperationsView()
            }
    }
}

/// One mailbox row inside an account section. Kept separate from
/// `SidebarView` so the nested label, unread badge, and modifier chain are
/// type-checked independently.
struct MailboxRow: View {
    let accountId: String
    let mailbox: MailboxRecord
    let mailboxId: Int64
    let isSelected: Bool
    let unreadCount: Int?
    let onTap: (SidebarSelection) -> Void

    private var mailboxSelection: SidebarSelection {
        .mailbox(MailboxSelection(accountId: accountId, mailboxId: mailboxId))
    }

    var body: some View {
        Button {
            onTap(mailboxSelection)
        } label: {
            HStack {
                Label(mailbox.displayPath, systemImage: icon(for: mailbox.role))
                Spacer()
                if let unreadCount, unreadCount > 0 {
                    UnreadCountBadge(count: unreadCount)
                        .accessibilityIdentifier("sidebar.mailbox.\(accountId).\(mailbox.path).unreadBadge")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? OtegamiColor.paleBase : nil)
        .accessibilityIdentifier("sidebar.mailbox.\(accountId).\(mailbox.path)")
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

/// M10 unread-count badge for sidebar rows.
///
/// 2026-08-07 (メイン UI の macOS ネイティブ化): macOS は Mail.app /
/// Finder のサイドバーと同じ「素の数字テキスト (セカンダリ色)」— 青い
/// カプセルは iOS のハンバーガーメニュー用の意匠として iOS だけに残す。
struct UnreadCountBadge: View {
    let count: Int

    private var displayText: String {
        count > 99 ? "99+" : "\(count)"
    }

    var body: some View {
        #if os(macOS)
        Text(displayText)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
        #else
        Text(displayText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(OtegamiColor.accent))
        #endif
    }
}
