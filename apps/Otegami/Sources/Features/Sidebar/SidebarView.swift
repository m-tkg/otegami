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

    @State private var showingAccountSetup = false
    @State private var showingSettings = false
    @State private var mailboxesByAccountId: [String: [MailboxRecord]] = [:]

    var body: some View {
        List(selection: $selection) {
            if environment.accounts.isEmpty {
                ContentUnavailableView {
                    Label("アカウントがありません", systemImage: "envelope.badge")
                } description: {
                    Text("メールアカウントを追加してください。")
                } actions: {
                    Button("アカウントを追加") { showingAccountSetup = true }
                        .accessibilityIdentifier("sidebar.addAccountButton")
                }
            } else {
                Section {
                    Label("すべての受信トレイ", systemImage: "tray.2")
                        .tag(SidebarSelection.unifiedInbox)
                        .accessibilityIdentifier("sidebar.unifiedInbox")
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
                    showingAccountSetup = true
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
        .sheet(isPresented: $showingAccountSetup) {
            AccountSetupView()
        }
        .sheet(isPresented: $showingSettings) {
            AccountsSettingsView()
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
