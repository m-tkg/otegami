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
    // By id (`MessageRecord` isn't `Hashable`). Set directly from a
    // `Button` action per row — the compact-width column push to
    // `MessageView` once this changes is driven by `RootView`'s
    // `preferredCompactColumn`; see its doc comment.
    @Binding var selectedMessageId: Int64?

    @State private var messages: [MessageRecord] = []
    @State private var isSyncing = false
    @State private var syncErrorMessage: String?

    var body: some View {
        List {
            ForEach(messages) { message in
                if let messageId = message.id {
                    Button {
                        selectedMessageId = messageId
                    } label: {
                        MessageRow(message: message)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("messageList.row.\(messageId)")
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteMessage(message)
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                        .accessibilityIdentifier("messageList.row.\(messageId).delete")
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            toggleRead(message)
                        } label: {
                            if message.flags.contains(.seen) {
                                Label("未読にする", systemImage: "envelope.badge")
                            } else {
                                Label("既読にする", systemImage: "envelope.open")
                            }
                        }
                        .tint(.accentColor)
                        .accessibilityIdentifier("messageList.row.\(messageId).toggleRead")
                    }
                }
            }
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

    /// Pull-to-refresh / the toolbar refresh button: differential sync
    /// (M3), not `syncAccount`'s full initial-sync window — this is called
    /// repeatedly over an account's lifetime, so it should only fetch
    /// what's actually changed. Replays any queued offline operations
    /// first, since "the user explicitly asked to reconnect" is exactly
    /// the moment those should get a chance to flush too.
    private func refresh() async {
        guard let account = environment.accounts.first(where: { $0.id == selection.accountId }) else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            guard let password = try environment.credentialStore.password(forAccountId: account.id) else {
                syncErrorMessage = "保存された資格情報が見つかりません。アカウントを再追加してください。"
                return
            }
            let auth = MailAuth.password(username: account.imapUsername, password: password)
            _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
            _ = try await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth)
        } catch {
            syncErrorMessage = "\(error)"
        }
    }

    // MARK: - Swipe actions (M3: opQueue-backed read/unread + delete)

    /// Toggles `\Seen` locally (instant UI feedback) and enqueues the
    /// resulting absolute flag state for `OpQueueProcessor` to mirror to
    /// the server, then makes a best-effort replay attempt right away
    /// (harmless no-op if offline — the queued op just waits for the next
    /// successful connection).
    private func toggleRead(_ message: MessageRecord) {
        guard let messageId = message.id else { return }
        let accountId = selection.accountId
        let mailboxId = selection.mailboxId
        Task {
            do {
                try await environment.database.dbWriter.write { db in
                    guard var record = try MessageRecord.fetchOne(db, key: messageId) else { return }
                    guard let mailbox = try MailboxRecord.fetchOne(db, key: mailboxId) else { return }
                    record.flags.formSymmetricDifference(.seen)
                    record.updatedAt = Date()
                    try record.update(db)
                    try OpQueue.enqueueSetFlags(
                        accountId: accountId, mailboxId: mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [UInt32(record.uid)], flags: record.flags, db: db
                    )
                }
                await replayOpQueueSoon()
            } catch {
                // Best-effort: the row simply doesn't update if this fails.
            }
        }
    }

    /// Removes the message from the local list immediately (optimistic —
    /// this mailbox's `ValueObservation` picks up the deletion right away)
    /// and enqueues a `delete` op (opQueue resolves the account's Trash
    /// mailbox and issues the actual `MOVE` at replay time).
    private func deleteMessage(_ message: MessageRecord) {
        guard let messageId = message.id, let uid = UInt32(exactly: message.uid) else { return }
        let accountId = selection.accountId
        let mailboxId = selection.mailboxId
        Task {
            do {
                try await environment.database.dbWriter.write { db in
                    guard let mailbox = try MailboxRecord.fetchOne(db, key: mailboxId) else { return }
                    try OpQueue.enqueueDelete(
                        accountId: accountId, sourceMailboxId: mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [uid], db: db
                    )
                    try MessageRecord.deleteOne(db, key: messageId)
                }
                await replayOpQueueSoon()
            } catch {
                // Best-effort: the row stays if this fails; the swipe can
                // be retried.
            }
        }
    }

    private func replayOpQueueSoon() async {
        guard let account = environment.accounts.first(where: { $0.id == selection.accountId }) else { return }
        guard let password = try? environment.credentialStore.password(forAccountId: account.id) else { return }
        let auth = MailAuth.password(username: account.imapUsername, password: password)
        _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
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
        .contentShape(Rectangle())
    }

    private var senderText: String {
        guard let from = message.fromAddresses.first else { return "(unknown)" }
        return from.name?.isEmpty == false ? from.name! : from.address
    }
}
