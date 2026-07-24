import SwiftUI
import GoogleOAuth
import OtegamiCore
import OtegamiStore
import SyncEngine
import MailTransport

/// The selected sidebar item's threads, newest-first (M4: thread rows, not
/// individual messages — plan: "MessageListView をスレッド単位表示に変更").
/// Works fully offline: it only ever reads from `AppDatabase`, either one
/// mailbox's threads (`SidebarSelection.mailbox`) or the cross-account
/// "すべての受信トレイ" unified inbox (`SidebarSelection.unifiedInbox`, plan:
/// "アカウント境界を跨いだスレッド結合はしない" — each row is still one
/// account's thread, just interleaved by date across accounts). Refreshing
/// (pull-to-refresh or the toolbar button) is what triggers `SyncCoordinator`
/// to talk to the server; with no network the list still renders whatever's
/// already stored.
///
/// Also hosts M7's search bar: `.searchable` on this same `List` rather than
/// a separate `SearchView`/screen, since a search-bar-over-a-list is exactly
/// this view's existing shape, right down to reusing `ThreadRow` and the
/// swipe actions for search results — SwiftUI's `.searchable` is designed to
/// attach to the view it filters, not to replace it with another one.
struct MessageListView: View {
    @Environment(AppEnvironment.self) private var environment
    let selection: SidebarSelection
    // By id (`ThreadRecord` isn't `Hashable` in the `List(selection:)`
    // sense this project uses — see M2's doc note on why rows are plain
    // `Button`s instead). Set directly from a `Button` action per row; the
    // compact-width column push to `ThreadDetailView` once this changes is
    // driven by `RootView`'s `preferredCompactColumn`.
    @Binding var selectedThreadId: Int64?

    @State private var summaries: [ThreadSummary] = []
    @State private var isSyncing = false
    @State private var syncErrorMessage: String?

    // MARK: - Search (M7)

    @State private var searchText = ""
    @State private var searchScope: SearchScopeOption = .all
    @State private var searchResults: [ThreadSummary] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    /// Restarts the thread observation whenever the selection changes *or*
    /// the account list changes — the latter matters for the unified inbox:
    /// adding a second account (M4 verification scenario (c)) should widen
    /// which accounts' inbox threads it observes without needing a manual
    /// refresh or relaunch.
    private struct ObservationKey: Hashable {
        var selection: SidebarSelection
        var accountIds: [String]
    }

    /// Whitespace-only input (including the empty string right after
    /// `.searchable` clears) is "not searching" — the normal `summaries`
    /// list shows, exactly like before M7.
    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the `List` actually renders: search results while a query is
    /// active, the live `ThreadQuery` observation otherwise. Rows,
    /// `ThreadRow`, and both swipe actions are shared between the two —
    /// marking a search hit read or deleting it works exactly like it does
    /// from the normal list.
    private var displayedSummaries: [ThreadSummary] {
        isSearchActive ? searchResults : summaries
    }

    /// "現在のメールボックス" only means something with one specific mailbox
    /// selected; the unified inbox has no single mailbox to narrow to, so
    /// its scope picker only ever offers "すべて".
    private var availableScopes: [SearchScopeOption] {
        switch selection {
        case .mailbox: [.all, .currentMailbox]
        case .unifiedInbox: [.all]
        }
    }

    var body: some View {
        List {
            ForEach(displayedSummaries) { summary in
                if let threadId = summary.thread.id {
                    Button {
                        selectedThreadId = threadId
                    } label: {
                        ThreadRow(summary: summary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("messageList.row.\(threadId)")
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteThread(summary)
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                        .accessibilityIdentifier("messageList.row.\(threadId).delete")
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            toggleRead(summary)
                        } label: {
                            if summary.thread.unreadCount > 0 {
                                Label("既読にする", systemImage: "envelope.open")
                            } else {
                                Label("未読にする", systemImage: "envelope.badge")
                            }
                        }
                        .tint(.accentColor)
                        .accessibilityIdentifier("messageList.row.\(threadId).toggleRead")
                    }
                }
            }
        }
        .accessibilityIdentifier("messageList.list")
        .navigationTitle(title)
        .overlay {
            if isSearchActive {
                if isSearching {
                    ProgressView("検索中…")
                        .accessibilityIdentifier("messageList.search.loading")
                } else if searchResults.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .accessibilityIdentifier("messageList.search.emptyState")
                }
            } else if summaries.isEmpty {
                ContentUnavailableView(
                    "メッセージがありません",
                    systemImage: "envelope",
                    description: Text(isSyncing ? "同期中…" : "再同期を試してください。")
                )
                .accessibilityIdentifier("messageList.emptyState")
            }
        }
        .searchable(text: $searchText, prompt: "検索")
        .accessibilityIdentifier("messageList.search.field")
        .searchScopes($searchScope) {
            ForEach(availableScopes) { scope in
                Text(scope.title)
                    .tag(scope)
                    .accessibilityIdentifier("messageList.search.scope.\(scope.rawValue)")
            }
        }
        .onChange(of: searchText) { _, _ in scheduleSearch() }
        .onChange(of: searchScope) { _, _ in scheduleSearch() }
        .onChange(of: selection) { _, _ in
            if !availableScopes.contains(searchScope) { searchScope = .all }
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
        .task(id: ObservationKey(selection: selection, accountIds: environment.accounts.map(\.id))) {
            await observeThreads()
        }
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

    private var title: String {
        switch selection {
        case .unifiedInbox:
            "すべての受信トレイ"
        case .mailbox(let mailboxSelection):
            environment.accounts.first { $0.id == mailboxSelection.accountId }.map { $0.displayName } ?? "Inbox"
        }
    }

    private func observeThreads() async {
        switch selection {
        case .mailbox(let mailboxSelection):
            let observation = ThreadQuery.summariesObservation(mailboxId: mailboxSelection.mailboxId)
            do {
                for try await fetched in observation.values(in: environment.database.dbWriter) {
                    summaries = fetched
                }
            } catch {
                // A failing observation just stops the list from updating
                // further; it doesn't clear what's already shown.
            }
        case .unifiedInbox:
            let accountIds = environment.accounts.map(\.id)
            let observation = ThreadQuery.unifiedInboxSummariesObservation(accountIds: accountIds)
            do {
                for try await fetched in observation.values(in: environment.database.dbWriter) {
                    summaries = fetched
                }
            } catch {
                // Same as above.
            }
        }
    }

    // MARK: - Search (M7)

    /// Debounces `searchText`/`searchScope` changes by 300ms (plan: "入力
    /// 300ms デバウンス") before actually querying — cancels whatever search
    /// was already in flight so a fast typist never races two queries
    /// against the same `searchResults` state. Clearing the field (`
    /// isSearchActive == false`) skips the debounce and the query
    /// entirely: there's nothing to search, and the normal list should
    /// reappear immediately rather than after a delay.
    private func scheduleSearch() {
        searchTask?.cancel()
        guard isSearchActive else {
            isSearching = false
            searchResults = []
            return
        }
        let query = searchText
        let scope = searchScope
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(query: query, scope: scope)
        }
    }

    private func performSearch(query: String, scope: SearchScopeOption) async {
        let storeScope: OtegamiStore.SearchScope
        switch (selection, scope) {
        case (.mailbox(let mailboxSelection), .currentMailbox):
            storeScope = .mailbox(mailboxId: mailboxSelection.mailboxId)
        default:
            storeScope = .allAccounts(accountIds: environment.accounts.map(\.id))
        }
        do {
            let results = try await environment.database.dbWriter.read { db in
                try SearchQuery.threadSummaries(query: query, scope: storeScope, db: db)
            }
            guard !Task.isCancelled else { return }
            searchResults = results
        } catch {
            guard !Task.isCancelled else { return }
            searchResults = []
        }
        isSearching = false
    }

    /// Pull-to-refresh / the toolbar refresh button: differential sync
    /// (M3), scoped (M4) to whichever mailbox is actually being viewed —
    /// a single mailbox for `.mailbox`, or every account's INBOX for the
    /// unified inbox (plan: "サイドバー選択時 + 手動更新"). Replays any
    /// queued offline operations first, since "the user explicitly asked
    /// to reconnect" is exactly the moment those should get a chance to
    /// flush too.
    private func refresh() async {
        isSyncing = true
        defer { isSyncing = false }

        switch selection {
        case .mailbox(let mailboxSelection):
            guard let account = environment.accounts.first(where: { $0.id == mailboxSelection.accountId }) else { return }
            do {
                let auth: MailAuth
                do {
                    auth = try await environment.auth(for: account)
                } catch TokenStoreError.reauthenticationRequired {
                    syncErrorMessage = "再認証が必要です。設定からアカウントを再認証してください。"
                    return
                } catch {
                    syncErrorMessage = "保存された資格情報が見つかりません。アカウントを再追加してください。"
                    return
                }
                let mailboxPath = try await environment.database.dbWriter.read { db in
                    try MailboxRecord.fetchOne(db, key: mailboxSelection.mailboxId)?.path
                }
                _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
                if let mailboxPath {
                    _ = try await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth, scope: .mailbox(path: mailboxPath))
                } else {
                    _ = try await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth)
                }
            } catch {
                syncErrorMessage = "\(error)"
            }
        case .unifiedInbox:
            for account in environment.accounts {
                guard let auth = try? await environment.auth(for: account) else { continue }
                _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
                _ = try? await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth, scope: .inboxOnly)
            }
        }
    }

    // MARK: - Swipe actions (M4: thread-wide, applied to every message)

    /// Toggles every message in the thread to the opposite of the thread's
    /// current unread state (any unread → mark the whole thread read;
    /// fully read → mark it all unread again), enqueuing an absolute
    /// `setFlags` op per affected message (plan: "全メッセージへ適用、opQueue
    /// 経由") and making a best-effort replay attempt right away.
    private func toggleRead(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        let markingRead = summary.thread.unreadCount > 0
        Task {
            do {
                try await environment.database.dbWriter.write { db in
                    let messages = try ThreadQuery.messages(threadId: threadId, db: db)
                    for var message in messages {
                        if markingRead {
                            guard !message.flags.contains(.seen) else { continue }
                            message.flags.insert(.seen)
                        } else {
                            guard message.flags.contains(.seen) else { continue }
                            message.flags.remove(.seen)
                        }
                        message.updatedAt = Date()
                        try message.update(db)
                        guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
                        try OpQueue.enqueueSetFlags(
                            accountId: accountId, mailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                            uids: [UInt32(message.uid)], flags: message.flags, db: db
                        )
                    }
                    try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
                }
                await replayOpQueueSoon(accountId: accountId)
            } catch {
                // Best-effort: the row simply doesn't update if this fails.
            }
        }
    }

    /// Removes every message in the thread from the local list immediately
    /// (optimistic — the mailbox's/unified inbox's `ValueObservation` picks
    /// up the deletion right away, and `ThreadAssigner.recomputeAggregates`
    /// deletes the now-empty `thread` row) and enqueues one `delete` op per
    /// message (opQueue resolves each message's own account's Trash
    /// mailbox and issues the actual `MOVE` at replay time).
    private func deleteThread(_ summary: ThreadSummary) {
        guard let threadId = summary.thread.id else { return }
        let accountId = summary.thread.accountId
        Task {
            do {
                try await environment.database.dbWriter.write { db in
                    let messages = try ThreadQuery.messages(threadId: threadId, db: db)
                    for message in messages {
                        guard let messageId = message.id, let uid = UInt32(exactly: message.uid) else { continue }
                        guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
                        try OpQueue.enqueueDelete(
                            accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                            uids: [uid], db: db
                        )
                        // M7: `messageSearchIndex` isn't a real foreign-keyed
                        // table, so this deletion needs its own explicit
                        // index cleanup alongside the `message` row's.
                        try FTSIndexer.delete(messageId: messageId, db: db)
                        try MessageRecord.deleteOne(db, key: messageId)
                    }
                    try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
                }
                // `searchResults` is a one-shot array, not a live
                // `ValueObservation` like `summaries` — the normal list
                // picks up a deletion automatically, but a search-mode row
                // needs this explicit nudge or the just-deleted thread
                // would keep showing until the next debounced re-search.
                if isSearchActive {
                    searchResults.removeAll { $0.id == summary.id }
                }
                await replayOpQueueSoon(accountId: accountId)
            } catch {
                // Best-effort: whatever's left stays if this fails; the
                // swipe can be retried.
            }
        }
    }

    private func replayOpQueueSoon(accountId: String) async {
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
        guard let auth = try? await environment.auth(for: account) else { return }
        _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
    }
}

private struct ThreadRow: View {
    let summary: ThreadSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(summary.thread.unreadCount > 0 ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(senderText)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(subjectText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if summary.thread.messageCount > 1 {
                        Text("\(summary.thread.messageCount)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                            .accessibilityIdentifier("messageList.row.\(summary.id).countBadge")
                    }
                }
                if let snippet = summary.latestMessage?.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let date = summary.thread.lastMessageDate {
                Text(date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var senderText: String {
        guard let from = summary.latestMessage?.fromAddresses.first else { return "(unknown)" }
        return from.name?.isEmpty == false ? from.name! : from.address
    }

    private var subjectText: String {
        let subject = summary.latestMessage?.subject ?? summary.thread.normalizedSubject
        return subject?.isEmpty == false ? subject! : "(件名なし)"
    }
}
