import SwiftUI
import GRDB
import OtegamiStore
import SyncEngine

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
    /// M10: resumes a saved draft — see `DraftsView`'s doc comment for why
    /// this is a callback owned by `RootView` rather than something
    /// `DraftsView` presents itself.
    var onOpenDraft: (Int64) -> Void = { _ in }

    /// M6: drives the whole add-account flow (type picker → the chosen
    /// form) as a single `.sheet(item:)` — see `AccountEntryRoute`'s doc
    /// comment for why a route enum rather than a `Bool`.
    @State private var accountEntryRoute: AccountEntryRoute?
    @State private var showingSettings = false
    @State private var showingOutbox = false
    @State private var showingDrafts = false
    @State private var showingFailedOps = false
    @State private var mailboxesByAccountId: [String: [MailboxRecord]] = [:]
    @State private var outboxCount = 0
    @State private var draftCount = 0
    @State private var failedOpCount = 0
    // M10: unread badges. `unreadByMailboxId` groups by mailbox id (spans
    // every account — a plain `[Int64: Int]` is enough since `MailboxRecord
    // .id` is a global autoincrement primary key, not scoped per account).
    // `unifiedInboxUnread` is its own separately-observed total rather than
    // derived by summing `unreadByMailboxId` client-side, since it's scoped
    // to inbox-role mailboxes only (`MessageQuery.unifiedInboxUnreadCount`'s
    // doc comment) — deriving it here would need this view to also know
    // each mailbox's role, duplicating logic the query already encodes.
    @State private var unreadByMailboxId: [Int64: Int] = [:]
    @State private var unifiedInboxUnread = 0

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
                    HStack {
                        Label("すべての受信トレイ", systemImage: "tray.2")
                        Spacer()
                        if unifiedInboxUnread > 0 {
                            UnreadCountBadge(count: unifiedInboxUnread)
                                .accessibilityIdentifier("sidebar.unifiedInbox.unreadBadge")
                        }
                    }
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

                    if draftCount > 0 {
                        Button {
                            showingDrafts = true
                        } label: {
                            Label("下書き (\(draftCount))", systemImage: "doc")
                        }
                        .accessibilityIdentifier("sidebar.drafts")
                    }

                    if failedOpCount > 0 {
                        Button {
                            showingFailedOps = true
                        } label: {
                            Label("同期エラー (\(failedOpCount))", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        .accessibilityIdentifier("sidebar.failedOps")
                    }
                }

                ForEach(environment.accounts) { account in
                    Section(account.displayName) {
                        ForEach(mailboxesByAccountId[account.id] ?? []) { mailbox in
                            if let mailboxId = mailbox.id {
                                HStack {
                                    Label(mailbox.displayPath, systemImage: icon(for: mailbox.role))
                                    Spacer()
                                    if let unread = unreadByMailboxId[mailboxId], unread > 0 {
                                        UnreadCountBadge(count: unread)
                                            .accessibilityIdentifier("sidebar.mailbox.\(account.id).\(mailbox.path).unreadBadge")
                                    }
                                }
                                .tag(SidebarSelection.mailbox(MailboxSelection(accountId: account.id, mailboxId: mailboxId)))
                                .accessibilityIdentifier("sidebar.mailbox.\(account.id).\(mailbox.path)")
                            }
                        }
                    }
                    .task(id: account.id) {
                        await observeMailboxes(accountId: account.id)
                    }
                    .task(id: account.id) {
                        await observeUnreadCounts(accountId: account.id)
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
        .sheet(isPresented: $showingDrafts) {
            DraftsView(onOpenDraft: onOpenDraft)
        }
        .sheet(isPresented: $showingFailedOps) {
            FailedOperationsView()
        }
        .task(id: environment.accounts.map(\.id)) { await observeOutbox() }
        .task(id: environment.accounts.map(\.id)) { await observeDraftCount() }
        .task(id: environment.accounts.map(\.id)) { await observeFailedOpCount() }
        .task(id: environment.accounts.map(\.id)) { await observeUnifiedInboxUnreadCount() }
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

    private func observeDraftCount() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = DraftQuery.observation(accountIds: accountIds)
        do {
            for try await drafts in observation.values(in: environment.database.dbWriter) {
                draftCount = drafts.count
            }
        } catch {
            // A failing observation just stops the badge from updating.
        }
    }

    /// M10: the "すべての受信トレイ" badge — re-observed whenever the
    /// account list changes (adding/removing an account widens/narrows
    /// which inbox-role mailboxes count toward the total), same trigger
    /// `observeOutbox()` already uses.
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

    /// Per-mailbox unread badges for one account's section — runs
    /// alongside `observeMailboxes(accountId:)` (same lifetime, via a
    /// second `.task(id:)` on the same `Section`) rather than folded into
    /// it, since the two observe different tables (`mailbox` vs. `message`)
    /// and there's no reason a `mailbox` row change should wait on/block a
    /// `message` count re-fetch or vice versa.
    private func observeUnreadCounts(accountId: String) async {
        let observation = MessageQuery.unreadCountsObservation(accountId: accountId)
        do {
            for try await counts in observation.values(in: environment.database.dbWriter) {
                for (mailboxId, count) in counts {
                    unreadByMailboxId[mailboxId] = count
                }
                // A mailbox that just went from "has unread" to "fully
                // read" drops out of `counts` entirely (`MessageQuery
                // .unreadCounts`'s doc comment) — without this, its badge
                // would keep showing the last-known nonzero count forever.
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

/// M10: unread-count pill for a sidebar row — matches the system Mail app's
/// look (a filled capsule, not a plain number) closely enough to read as
/// "standard" rather than a bespoke control. Caps the displayed text at
/// "99+" rather than ever showing an unbounded number: a three-figure badge
/// starts fighting the row's trailing edge for space, and "exactly how many
/// hundred" isn't information worth that cost once it's already "a lot."
private struct UnreadCountBadge: View {
    let count: Int

    private var displayText: String {
        count > 99 ? "99+" : "\(count)"
    }

    var body: some View {
        Text(displayText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor))
    }
}
