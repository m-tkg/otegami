import SwiftUI
import OtegamiStore
import SyncEngine
import MailTransport

/// The selected mailbox's messages, newest first, live via
/// `MessageQuery.observation`. Works fully offline: it only ever reads
/// from `AppDatabase` — refreshing (pull-to-refresh or the toolbar button)
/// is what triggers `SyncCoordinator` to talk to the server, but with no
/// network the list still renders whatever's already stored.
struct MessageListView: View {
    @Environment(AppEnvironment.self) private var environment
    let selection: MailboxSelection

    @State private var messages: [MessageRecord] = []
    @State private var isSyncing = false
    @State private var syncErrorMessage: String?

    var body: some View {
        List(messages) { message in
            MessageRow(message: message)
                .accessibilityIdentifier("messageList.row.\(message.id.map(String.init) ?? "?")")
        }
        .accessibilityIdentifier("messageList.list")
        .navigationTitle(mailboxTitle)
        .overlay {
            if messages.isEmpty {
                ContentUnavailableView(
                    "メッセージがありません",
                    systemImage: "envelope",
                    description: Text(isSyncing ? "同期中…" : "再同期を試してください。")
                )
                .accessibilityIdentifier("messageList.emptyState")
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await refresh() }
                } label: {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Label("再同期", systemImage: "arrow.clockwise")
                    }
                }
                .accessibilityIdentifier("messageList.refreshButton")
                .disabled(isSyncing)
            }
        }
        #if os(iOS)
        .refreshable { await refresh() }
        #endif
        .task(id: selection) { await observeMessages() }
        .alert(
            "同期エラー",
            isPresented: Binding(
                get: { syncErrorMessage != nil },
                set: { if !$0 { syncErrorMessage = nil } }
            )
        ) {
            Button("OK") { syncErrorMessage = nil }
        } message: {
            Text(syncErrorMessage ?? "")
        }
    }

    private var mailboxTitle: String {
        environment.accounts
            .first { $0.id == selection.accountId }
            .map { $0.displayName } ?? "Inbox"
    }

    private func observeMessages() async {
        let observation = MessageQuery.observation(mailboxId: selection.mailboxId)
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                messages = fetched
            }
        } catch {
            // A failing observation just stops the list from updating
            // further; it doesn't clear what's already shown.
        }
    }

    private func refresh() async {
        guard let account = environment.accounts.first(where: { $0.id == selection.accountId }) else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            guard let password = try environment.credentialStore.password(forAccountId: account.id) else {
                syncErrorMessage = "保存された資格情報が見つかりません。アカウントを再追加してください。"
                return
            }
            _ = try await environment.syncCoordinator.syncAccount(
                account,
                auth: .password(username: account.imapUsername, password: password)
            )
        } catch {
            syncErrorMessage = "\(error)"
        }
    }
}

private struct MessageRow: View {
    let message: MessageRecord

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.flags.contains(.seen) ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(senderText)
                    .font(.headline)
                    .lineLimit(1)
                Text(message.subject?.isEmpty == false ? message.subject! : "(件名なし)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(message.internalDate, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var senderText: String {
        guard let from = message.fromAddresses.first else { return "(unknown)" }
        return from.name?.isEmpty == false ? from.name! : from.address
    }
}
