import SwiftUI
import MailTransport
import OtegamiStore

@main
struct OtegamiApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
    }
}

/// Three-pane scaffold: account/mailbox sidebar, the selected mailbox's
/// message list, and the selected message's body (M2's `MessageView`).
/// Sidebar and message list are both backed by live GRDB
/// `ValueObservation`s via `AppEnvironment`/`AppDatabase`.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: MailboxSelection?
    // By id, not the whole `MessageRecord` — `MessageRecord` isn't
    // `Hashable`, which `List(selection:)` requires.
    @State private var selectedMessageId: Int64?

    // Drives which column a compact-width device (iPhone) shows.
    // `NavigationSplitView` does *not* automatically push from `content`
    // to `detail` just because a `List(selection:)` binding changed value
    // — that's only guaranteed between `sidebar` and `content` (the
    // two-column case). For three columns, the documented way to make a
    // selection in `content` actually navigate to `detail` on compact
    // width is to drive `preferredCompactColumn` explicitly; discovered by
    // testing on a real (compact) simulator — tapping a message row
    // updated `selectedMessageId` correctly but never visibly navigated
    // without this.
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar

    // Remembers the last message opened per mailbox, so a cold relaunch
    // (verified by `scripts/verify-ios-m2.sh`'s offline checkpoint) can
    // show it again without another tap — `MessageView` reads an already-
    // fetched body straight from GRDB, so this alone is enough to prove
    // "read once, still readable with the mail server unreachable" without
    // needing any UI-automation step after the restart.
    @AppStorage("lastOpenedMessage.mailboxId") private var lastOpenedMailboxId: Int = 0
    @AppStorage("lastOpenedMessage.messageId") private var lastOpenedMessageId: Int = 0

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            SidebarView(selection: $selection)
        } content: {
            if let selection {
                MessageListView(selection: selection, selectedMessageId: $selectedMessageId)
            } else {
                ContentUnavailableView(
                    "メールボックスを選択してください",
                    systemImage: "tray",
                    description: Text("左のサイドバーからアカウントを追加、またはメールボックスを選択してください。")
                )
                .navigationTitle("Inbox")
            }
        } detail: {
            if let selection, let selectedMessageId {
                MessageView(selection: selection, messageId: selectedMessageId)
            } else {
                ContentUnavailableView(
                    "No Message Selected",
                    systemImage: "envelope.open"
                )
                .accessibilityIdentifier("messageDetail.emptyState")
            }
        }
        // A newly-selected mailbox invalidates whatever message was shown
        // from the previous one — otherwise the detail pane would keep
        // rendering a message that no longer belongs to the visible list.
        // Restoration (below) re-populates it if there's a remembered
        // message for the *new* selection.
        .onChange(of: selection) { _, newValue in
            selectedMessageId = nil
            preferredColumn = newValue == nil ? .sidebar : .content
        }
        .onChange(of: selectedMessageId) { _, newValue in
            guard let newValue, let selection else { return }
            lastOpenedMailboxId = Int(selection.mailboxId)
            lastOpenedMessageId = Int(newValue)
            preferredColumn = .detail
        }
        .task(id: selection) { restoreLastOpenedMessageIfNeeded() }
        // Foreground IDLE (M3, plan: "アプリ active 中、INBOX を IDLE"):
        // start every account's IDLE loop (plus one immediate opQueue
        // replay + incremental sync, since becoming active is exactly
        // when queued offline operations should get a chance to flush)
        // on `.active`, and stop them all on `.background`/`.inactive` —
        // there is no IMAP connection to keep alive while the app can't
        // run code.
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            Task { await handleScenePhaseChange(newPhase) }
        }
        // A newly-added account (mid-session, via AccountSetupView) should
        // also get an IDLE loop without waiting for the next background/
        // foreground transition.
        .onChange(of: environment.accounts) { _, newAccounts in
            guard scenePhase == .active else { return }
            Task { await startIdleLoops(for: newAccounts) }
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            await startIdleLoops(for: environment.accounts)
            await syncAllAccountsOnce()
        case .background, .inactive:
            await environment.syncCoordinator.stopAllIdleLoops()
        @unknown default:
            break
        }
    }

    private func startIdleLoops(for accounts: [AccountRecord]) async {
        for account in accounts {
            guard let auth = authForAccount(account) else { continue }
            await environment.syncCoordinator.startIdleLoop(for: account, auth: auth)
        }
    }

    /// One opQueue replay + incremental sync per account right as the app
    /// becomes active — an IDLE loop only wakes on the *next* server push,
    /// so without this a device that went offline, had changes queued,
    /// and came back online wouldn't flush/pick anything up until the next
    /// unrelated server event.
    private func syncAllAccountsOnce() async {
        for account in environment.accounts {
            guard let auth = authForAccount(account) else { continue }
            _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
            _ = try? await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth)
        }
    }

    private func authForAccount(_ account: AccountRecord) -> MailAuth? {
        guard let password = try? environment.credentialStore.password(forAccountId: account.id) else { return nil }
        return .password(username: account.imapUsername, password: password)
    }

    private func restoreLastOpenedMessageIfNeeded() {
        guard selectedMessageId == nil,
              let selection,
              lastOpenedMessageId != 0,
              Int64(lastOpenedMailboxId) == selection.mailboxId
        else { return }
        selectedMessageId = Int64(lastOpenedMessageId)
        preferredColumn = .detail
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment())
}
