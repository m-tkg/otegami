import SwiftUI
import GRDB
import OtegamiStore

/// Unified inbox + account/mailbox tree, backed by live `ValueObservation`s.
/// One mailbox observation per visible account (started/stopped as accounts
/// appear — `.task(id:)` handles that automatically). "すべての受信トレイ" (M4)
/// sits above every account's section and stays visible whenever at least
/// one account exists, regardless of how many.
struct SidebarView: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var selection: SidebarSelection?
    /// M5: opens `ComposerView` for a brand-new message — presentation
    /// itself (sheet on iOS, a separate window on macOS) is `RootView`'s
    /// job, since it's the common ancestor of both the sidebar's "作成"
    /// button and `ThreadDetailView`'s "返信"/"全員に返信" buttons.
    var onCompose: () -> Void = {}

    /// M6: drives the whole add-account flow (type picker → the chosen
    /// form) as a single `.sheet(item:)` — see `AccountEntryRoute`'s doc
    /// comment for why a route enum rather than a `Bool`.
    @State private var accountEntryRoute: AccountEntryRoute?
    @State private var showingSettings = false
    @State private var showingOutbox = false
    @State private var mailboxesByAccountId: [String: [MailboxRecord]] = [:]
    @State private var outboxCount = 0

    var body: some View {
        List(selection: $selection) {
            if environment.accounts.isEmpty {
                ContentUnavailableView {
                    Label("アカウントがありません", systemImage: "envelope.badge")
                } description: {
                    Text("メールアカウントを追加してください。")
                } actions: {
                    Button("アカウントを追加") { accountEntryRoute = .typeSelection }
                        .accessibilityIdentifier("sidebar.addAccountButton")
                }
            } else {
                Section {
                    Label("すべての受信トレイ", systemImage: "tray.2")
                        .tag(SidebarSelection.unifiedInbox)
                        .accessibilityIdentifier("sidebar.unifiedInbox")

                    if outboxCount > 0 {
                        Button {
                            showingOutbox = true
                        } label: {
                            Label("送信待ち (\(outboxCount))", systemImage: "tray.and.arrow.up")
                        }
                        .accessibilityIdentifier("sidebar.outbox")
                    }
                }

                ForEach(environment.accounts) { account in
                    Section(account.displayName) {
                        ForEach(mailboxesByAccountId[account.id] ?? []) { mailbox in
                            if let mailboxId = mailbox.id {
                                Label(mailbox.displayPath, systemImage: icon(for: mailbox.role))
                                    .tag(SidebarSelection.mailbox(MailboxSelection(accountId: account.id, mailboxId: mailboxId)))
                                    .accessibilityIdentifier("sidebar.mailbox.\(account.id).\(mailbox.path)")
                            }
                        }
                    }
                    .task(id: account.id) {
                        await observeMailboxes(accountId: account.id)
                    }
                }
            }
        }
        .accessibilityIdentifier("sidebar.list")
        .navigationTitle("Otegami")
        .toolbar {
            ToolbarItem {
                Button {
                    onCompose()
                } label: {
                    Label("作成", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("sidebar.composeButton")
                .disabled(environment.accounts.isEmpty)
            }
            ToolbarItem {
                Button {
                    accountEntryRoute = .typeSelection
                } label: {
                    Label("アカウントを追加", systemImage: "plus")
                }
                .accessibilityIdentifier("sidebar.addAccountToolbarButton")
            }
            ToolbarItem {
                Button {
                    showingSettings = true
                } label: {
                    Label("設定", systemImage: "gearshape")
                }
                .accessibilityIdentifier("sidebar.settingsButton")
            }
        }
        .sheet(item: $accountEntryRoute) { route in
            accountEntryDestination(for: route, binding: $accountEntryRoute)
        }
        .sheet(isPresented: $showingSettings) {
            AccountsSettingsView()
        }
        .sheet(isPresented: $showingOutbox) {
            OutboxView()
        }
        .task(id: environment.accounts.map(\.id)) { await observeOutbox() }
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

    /// Runs for as long as `SidebarView` shows `accountId`'s section
    /// (cancelled automatically by `.task(id:)` when the account
    /// disappears from the list). Also claims "すべての受信トレイ" as the
    /// initial selection the first time any account's mailboxes appear
    /// (M4) — launching the app with one or more accounts goes straight to
    /// a populated, threaded list without an extra tap.
    private func observeMailboxes(accountId: String) async {
        let observation = MailboxQuery.observation(accountId: accountId)
        do {
            for try await mailboxes in observation.values(in: environment.database.dbWriter) {
                mailboxesByAccountId[accountId] = mailboxes
                if selection == nil {
                    selection = .unifiedInbox
                }
            }
        } catch {
            // A failing mailbox observation for one account shouldn't take
            // down the sidebar; that account's section just stops updating.
        }
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
