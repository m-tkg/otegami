import SwiftUI
import GRDB
import OtegamiStore

/// Account/mailbox tree, backed by live `ValueObservation`s. One mailbox
/// observation per visible account (started/stopped as accounts appear —
/// `.task(id:)` handles that automatically); M1 only ever has one account
/// in practice, but this doesn't assume that.
struct SidebarView: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var selection: MailboxSelection?

    @State private var showingAccountSetup = false
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
                ForEach(environment.accounts) { account in
                    Section(account.displayName) {
                        ForEach(mailboxesByAccountId[account.id] ?? []) { mailbox in
                            if let mailboxId = mailbox.id {
                                Label(mailbox.displayPath, systemImage: icon(for: mailbox.role))
                                    .tag(MailboxSelection(accountId: account.id, mailboxId: mailboxId))
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
        }
        .sheet(isPresented: $showingAccountSetup) {
            AccountSetupView()
        }
    }

    /// Runs for as long as `SidebarView` shows `accountId`'s section
    /// (cancelled automatically by `.task(id:)` when the account
    /// disappears from the list). Also claims the account's INBOX as the
    /// initial selection the first time its mailboxes appear, so launching
    /// the app with one account goes straight to a populated message list.
    private func observeMailboxes(accountId: String) async {
        let observation = MailboxQuery.observation(accountId: accountId)
        do {
            for try await mailboxes in observation.values(in: environment.database.dbWriter) {
                mailboxesByAccountId[accountId] = mailboxes
                if selection == nil,
                   let inbox = mailboxes.first(where: { $0.role == .inbox }),
                   let inboxId = inbox.id {
                    selection = MailboxSelection(accountId: accountId, mailboxId: inboxId)
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
