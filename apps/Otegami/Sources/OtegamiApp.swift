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
        #if os(macOS)
        // M5 (plan: "macOS は別ウィンドウ (WindowGroup id \"composer\")"):
        // each compose/reply action opens its own window rather than a
        // sheet — `ComposerLaunchPayload` is `Codable`/`Hashable` so
        // `openWindow(id:value:)` (called from `RootView`) can pass it
        // straight through as this scene's launch value.
        WindowGroup("作成", id: "composer", for: ComposerLaunchPayload.self) { $payload in
            ComposerView(payload: payload ?? .new)
                .environment(environment)
        }
        .defaultSize(width: 560, height: 520)
        #endif
    }
}

/// Three-pane scaffold: account/mailbox sidebar, the selected mailbox's
/// message list, and the selected message's body (M2's `MessageView`).
/// Sidebar and message list are both backed by live GRDB
/// `ValueObservation`s via `AppEnvironment`/`AppDatabase`.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var selection: SidebarSelection?
    // M5: which composer to show. Only actually drives a `.sheet` on iOS
    // (macOS opens `openWindow(id: "composer", ...)` instead and never sets
    // this) — see `presentComposer(_:)`.
    @State private var composerPayload: ComposerLaunchPayload?
    // By id, not the whole `ThreadRecord` — `ThreadRecord` isn't
    // `Hashable`, which `List(selection:)` requires.
    @State private var selectedThreadId: Int64?

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

    // Remembers the last thread opened per sidebar selection, so a cold
    // relaunch (verified by `scripts/verify-ios-m2.sh`'s offline checkpoint,
    // and `scripts/verify-ios-m4.sh`'s thread-view checkpoint) can show it
    // again without another tap — `ThreadDetailView`/`MessageView` read an
    // already-fetched body straight from GRDB, so this alone is enough to
    // prove "read once, still readable with the mail server unreachable"
    // without needing any UI-automation step after the restart. Keyed by
    // a serialized `SidebarSelection` (M4: either "unified" or a mailbox
    // id) rather than just a mailbox id, since the unified inbox has no
    // single mailbox to key on.
    @AppStorage("lastOpenedThread.selectionKey") private var lastOpenedSelectionKey: String = ""
    @AppStorage("lastOpenedThread.threadId") private var lastOpenedThreadId: Int = 0

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            SidebarView(selection: $selection, onCompose: { presentComposer(.new) })
        } content: {
            if let selection {
                MessageListView(selection: selection, selectedThreadId: $selectedThreadId)
            } else {
                ContentUnavailableView(
                    "メールボックスを選択してください",
                    systemImage: "tray",
                    description: Text("左のサイドバーからアカウントを追加、またはメールボックスを選択してください。")
                )
                .navigationTitle("Inbox")
            }
        } detail: {
            if let selectedThreadId {
                ThreadDetailView(threadId: selectedThreadId, onReply: { messageId, replyAll in
                    presentComposer(.reply(originalMessageId: messageId, replyAll: replyAll))
                })
            } else {
                ContentUnavailableView(
                    "No Message Selected",
                    systemImage: "envelope.open"
                )
                .accessibilityIdentifier("messageDetail.emptyState")
            }
        }
        // A newly-selected sidebar item invalidates whatever thread was
        // shown from the previous one — otherwise the detail pane would
        // keep rendering a thread that no longer belongs to the visible
        // list. Restoration (below) re-populates it if there's a
        // remembered thread for the *new* selection.
        .onChange(of: selection) { _, newValue in
            selectedThreadId = nil
            preferredColumn = newValue == nil ? .sidebar : .content
        }
        .onChange(of: selectedThreadId) { _, newValue in
            guard let newValue, let selection else { return }
            lastOpenedSelectionKey = selectionKey(for: selection)
            lastOpenedThreadId = Int(newValue)
            preferredColumn = .detail
        }
        .task(id: selection) { restoreLastOpenedThreadIfNeeded() }
        #if os(iOS)
        .sheet(item: $composerPayload) { payload in
            ComposerView(payload: payload)
        }
        #endif
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

    private func restoreLastOpenedThreadIfNeeded() {
        // Verification-only escape hatch: `scripts/verify-ios-m4.sh` needs
        // a way to bring the app to the foreground for a screenshot
        // *without* re-opening whatever thread an earlier XCUITest phase
        // left as "last opened" — `xcrun simctl launch <device> <bundle-id>
        // -uiTestsSkipThreadRestoration` passes this as a launch argument
        // for exactly that. Never set by the app itself; harmless in
        // production since nothing else ever passes launch arguments.
        guard !ProcessInfo.processInfo.arguments.contains("-uiTestsSkipThreadRestoration") else { return }
        guard selectedThreadId == nil,
              let selection,
              lastOpenedThreadId != 0,
              lastOpenedSelectionKey == selectionKey(for: selection)
        else { return }
        selectedThreadId = Int64(lastOpenedThreadId)
        preferredColumn = .detail
    }

    /// Presents `ComposerView` for `payload` — a sheet on iOS
    /// (`composerPayload` drives `.sheet(item:)` above), a fresh window on
    /// macOS (`WindowGroup(id: "composer")` in `OtegamiApp`'s `Scene`
    /// body). Called from `SidebarView`'s "作成" button and
    /// `ThreadDetailView`'s "返信"/"全員に返信" buttons.
    private func presentComposer(_ payload: ComposerLaunchPayload) {
        #if os(macOS)
        openWindow(id: "composer", value: payload)
        #else
        composerPayload = payload
        #endif
    }

    private func selectionKey(for selection: SidebarSelection) -> String {
        switch selection {
        case .unifiedInbox: "unified"
        case .mailbox(let mailboxSelection): "mailbox:\(mailboxSelection.mailboxId)"
        }
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment())
}
