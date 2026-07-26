import SwiftUI
import OtegamiStore
import SyncEngine

@main
struct OtegamiApp: App {
    @State private var environment = AppEnvironment()
    #if os(iOS)
    // M9: only reason this app has a UIApplicationDelegate at all — see
    // PushTokenCenter.swift.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
        #if os(macOS)
        // M10: menu bar (⌘N/⌘R/⌘⌫/⌘⇧F/⌘]/⌘[) — `OtegamiCommands` reads its
        // actions via `@FocusedValue` (`AppFocusedValues.swift`), published
        // by `RootView`/`MessageListView` below. Attached to this scene
        // (not the "composer" `WindowGroup`) since Commands apply
        // app-wide regardless of which scene declares them; a composer
        // window intentionally doesn't publish any of these focused values
        // itself, so e.g. ⌘R inside a composer window just stays disabled
        // rather than trying to "reply to a reply."
        .commands { OtegamiCommands() }
        #endif
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
        #if os(macOS)
        // M10: the native Settings scene (⌘,/App menu → Settings…) —
        // `OtegamiSettingsView`'s doc comment explains why it wraps rather
        // than replaces the existing gear-icon sheet.
        Settings {
            OtegamiSettingsView()
                .environment(environment)
        }
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

    // Remembers the last thread opened per sidebar selection so that
    // switching *back* to a mailbox later in the same session reopens
    // whatever thread was last read there, without another tap. Keyed by a
    // serialized `SidebarSelection` (M4: either "unified" or a mailbox id)
    // rather than just a mailbox id, since the unified inbox has no single
    // mailbox to key on.
    //
    // Deliberately plain `@State` (in-memory only), not `@AppStorage` —
    // it originally persisted across launches, verified by
    // `scripts/verify-ios-m2.sh`'s offline checkpoint and
    // `scripts/verify-ios-m4.sh`'s thread-view checkpoint, but that turned
    // into a real-device bug (docs/verify.md): killing and relaunching the
    // app with a thread previously open jumped straight back into
    // `ThreadDetailView` with no tap, and that view's `MessageView`/
    // `HTMLMessageView` weren't ready to be the *first* thing on screen
    // (see `ThreadDetailView.expandedMessageHeight(in:)`'s doc comment for
    // the layout collapse this exposed).
    //
    // A first attempt at fixing this kept `@AppStorage` but added a
    // one-shot "skip the very first restore call this process" latch —
    // that turned out not to be robust: `SidebarView`'s `List(selection:)`
    // binding (already flagged as flaky in this project — M2's pitfall #2,
    // `.claude/skills/verify/SKILL.md`) can genuinely oscillate `selection`
    // through nil and back to `.unifiedInbox` more than once while the
    // account/mailbox list is still loading in, each transition re-running
    // `.task(id: selection)` — so "skip exactly the first call" ended up
    // skipping the *spurious* first oscillation while still restoring on a
    // later one within the very same cold launch, confirmed via a fresh
    // `simctl erase` + XCUITest repro. Making this in-memory-only instead
    // sidesteps the whole class of problem structurally rather than by
    // counting calls: this dictionary starts *empty* every process launch,
    // so there is nothing to restore *from* no matter how many times or in
    // what order `selection` churns during startup — restoration can only
    // ever produce a thread this same running process itself opened.
    @State private var lastOpenedThreadIdBySelectionKey: [String: Int64] = [:]

    var body: some View {
        // Split into `navigationViewWithFocusedValues` (see its own doc
        // comment) plus this remaining modifier chain, rather than one
        // single expression running from `NavigationSplitView(...)` all the
        // way through every modifier below — the combined form measured at
        // 335ms to type-check on a fast local Mac under
        // `-warn-long-expression-type-checking` (`docs/ci.md`'s
        // troubleshooting notes), well above what's safe headroom for a
        // much slower CI runner. Splitting the chain into pieces here
        // (rather than only extracting the column closures) cuts the
        // remainder further, since a long `View` modifier chain is itself
        // one expression the type-checker must solve as a whole.
        rootContent
            #if os(iOS)
            .sheet(item: $composerPayload) { payload in
                ComposerView(payload: payload)
            }
            #endif
            // Foreground IDLE (M3, plan: "アプリ active 中、INBOX を IDLE"):
            // start every account's IDLE loop (plus one immediate opQueue
            // replay + incremental sync, since becoming active is exactly
            // when queued offline operations should get a chance to flush)
            // on `.active`, and stop them all on `.background`/`.inactive`
            // — there is no IMAP connection to keep alive while the app
            // can't run code.
            .onChange(of: scenePhase, initial: true) { _, newPhase in
                Task { await handleScenePhaseChange(newPhase) }
            }
            // A newly-added account (mid-session, via AccountSetupView)
            // should also get an IDLE loop without waiting for the next
            // background/foreground transition.
            .onChange(of: environment.accounts) { _, newAccounts in
                guard scenePhase == .active else { return }
                Task { await startIdleLoops(for: newAccounts) }
            }
    }

    /// design-phase-2 (1a): the actual top-level content, split by
    /// platform. iOS renders `OtegamiTabRootView`'s three-tab structure
    /// instead of `NavigationSplitView` entirely (`CLAUDE.md`'s adopted 1a
    /// decision — iOS-only, macOS keeps its three-pane layout unchanged);
    /// `presentComposer(_:)` is the one piece of behavior both platforms'
    /// root content still shares (a sheet on iOS, a separate window on
    /// macOS — see that method's doc comment), so it's passed straight
    /// through as a handful of closures rather than duplicated.
    #if os(iOS)
    private var rootContent: some View {
        OtegamiTabRootView(
            onCompose: { presentComposer(.new) },
            onOpenDraft: { draftId in presentComposer(.draft(draftId: draftId)) },
            onOpenServerDraft: { messageId in presentComposer(.serverDraft(messageId: messageId)) },
            onReply: { messageId, replyAll, translateToEnglish in
                presentComposer(.reply(originalMessageId: messageId, replyAll: replyAll, translateToEnglish: translateToEnglish))
            },
            onOpenCancelledSend: { snapshot in presentComposer(.cancelledSend(snapshot)) }
        )
    }
    #else
    private var rootContent: some View {
        navigationViewWithFocusedValues
    }
    #endif

    /// `navigationView` plus (macOS only) the five `focusedSceneValue`
    /// calls that publish `OtegamiCommands`' menu actions — kept as its own
    /// expression, separate from `body`'s `.sheet`/`.onChange` tail, since
    /// this chain of five ternary-typed `focusedSceneValue` calls turned
    /// out to be the single most expensive piece of the original combined
    /// expression to type-check (measured independently while narrowing
    /// down `body`'s 335ms total, `docs/ci.md`'s troubleshooting notes).
    #if os(macOS)
    private var navigationViewWithFocusedValues: some View {
        navigationView
            // M10: publishes the actions `OtegamiCommands`' menu items
            // invoke — `AppFocusedValues.swift`'s doc comment on why
            // `FocusedSceneValue` rather than passing closures some other
            // way. `replyAction`/`deleteAction` are only published while a
            // thread is actually open, so ⌘R/⌘⌫ disable themselves
            // automatically otherwise (no extra bookkeeping needed here
            // beyond the `nil`-vs-non-`nil` ternary).
            .focusedSceneValue(\.newMessageAction, environment.accounts.isEmpty ? nil : { presentComposer(.new) })
            .focusedSceneValue(\.replyAction, selectedThreadId == nil ? nil : { replyToSelectedThread() })
            .focusedSceneValue(\.deleteAction, selectedThreadId == nil ? nil : { deleteSelectedThread() })
            .focusedSceneValue(\.nextMailboxAction, environment.accounts.isEmpty ? nil : { cycleMailboxSelection(by: 1) })
            .focusedSceneValue(\.previousMailboxAction, environment.accounts.isEmpty ? nil : { cycleMailboxSelection(by: -1) })
    }
    #else
    private var navigationViewWithFocusedValues: some View {
        navigationView
    }
    #endif

    /// `splitView` plus the two modifiers most tightly coupled to
    /// `selection` itself — split out of `body` (see its doc comment) so
    /// this and the rest of `body`'s modifier chain are separate
    /// expressions for the type-checker.
    private var navigationView: some View {
        splitView
        // A newly-selected sidebar item invalidates whatever thread was
        // shown from the previous one — otherwise the detail pane would
        // keep rendering a thread that no longer belongs to the visible
        // list. Restoration (below) re-populates it if there's a
        // remembered thread for the *new* selection.
        //
        // Deliberately does *not* push `preferredColumn` forward here
        // anymore (it used to: `preferredColumn = newValue == nil ?
        // .sidebar : .content`) — two real bugs traced back to deriving
        // navigation from this value *changing* rather than from the
        // user's tap itself (docs/verify.md's cold-launch/sidebar-selection
        // investigation, the follow-up "コールドランチが統合受信トレイから
        // 始まる"/「直前に選択していた行」タップ不能 reports):
        //   1. `SidebarView.observeMailboxes(accountId:)`'s auto-select of
        //      `.unifiedInbox` on the very first mailbox load (below, via
        //      the `environment.accounts` `onChange`) also flows through
        //      this same `selection`, so pushing forward here meant *every*
        //      app launch with an existing account jumped straight past
        //      the sidebar into the message list — there was no way to
        //      land on the sidebar root first on a compact-width device.
        //   2. Re-tapping the row for the *already-selected* mailbox (e.g.
        //      after popping back to the sidebar via the system back
        //      button) doesn't change `selection`'s value, so this
        //      `onChange` simply never fires a second time — the column
        //      never gets pushed back forward, and the row looks broken.
        // `SidebarView.onSelected`/`MessageListView.onThreadSelected`
        // (wired above) are the only paths that push a column forward now,
        // and they do so unconditionally on every real tap regardless of
        // whether the underlying value actually changed — see their doc
        // comments. Falling back to `.sidebar` when a selection is cleared
        // (e.g. the account it pointed at was just deleted) is still a
        // safe, non-forward-pushing thing to do here.
        .onChange(of: selection) { oldValue, newValue in
            selectedThreadId = nil
            if newValue == nil {
                preferredColumn = .sidebar
            } else if oldValue == nil, uiTestsShouldAutoAdvanceToContent {
                // Legacy test-only shortcut — see `uiTestsShouldAutoAdvanceToContent`'s
                // doc comment. Only fires on the nil→non-nil transition
                // (the initial auto-select), matching exactly what the
                // pre-fix code did unconditionally for every transition.
                preferredColumn = .content
            }
        }
        .task(id: selection) { restoreLastOpenedThreadIfNeeded() }
    }

    /// The bare three-column `NavigationSplitView`, with no modifiers
    /// attached — split out of `body` (see its doc comment) so this and
    /// each column closure below are their own expressions for the
    /// type-checker rather than one combined with `body`'s whole modifier
    /// chain.
    private var splitView: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            sidebarColumn
        } content: {
            contentColumn
        } detail: {
            detailColumn
        }
    }

    private var sidebarColumn: some View {
        SidebarView(
            selection: $selection,
            onSelected: { _ in preferredColumn = .content },
            onCompose: { presentComposer(.new) },
            onOpenDraft: { draftId in presentComposer(.draft(draftId: draftId)) },
            onOpenServerDraft: { messageId in presentComposer(.serverDraft(messageId: messageId)) }
        )
    }

    private var contentColumn: some View {
        Group {
            if let selection {
                MessageListView(
                    selection: selection,
                    selectedThreadId: $selectedThreadId,
                    onThreadSelected: { threadId in selectThread(threadId, under: selection) }
                )
            } else {
                ContentUnavailableView(
                    "メールボックスを選択してください",
                    systemImage: "tray",
                    description: Text("左のサイドバーからアカウントを追加、またはメールボックスを選択してください。")
                )
                .navigationTitle("Inbox")
            }
        }
    }

    private var detailColumn: some View {
        Group {
            if let selectedThreadId {
                ThreadDetailView(threadId: selectedThreadId, onReply: { messageId, replyAll, translateToEnglish in
                    presentComposer(.reply(originalMessageId: messageId, replyAll: replyAll, translateToEnglish: translateToEnglish))
                })
            } else {
                ContentUnavailableView(
                    "No Message Selected",
                    systemImage: "envelope.open"
                )
                .accessibilityIdentifier("messageDetail.emptyState")
            }
        }
    }

    /// Set only by this project's own XCUITest/verify-script infrastructure
    /// (`scripts/verify-ios-*.sh`'s `screenshot`/`screenshotForeground`
    /// helpers, and the handful of existing `OtegamiUITests` suites that
    /// aren't specifically testing cold-launch navigation) — never passed
    /// by a real launch. Restores the pre-fix "cold launch with an
    /// existing account jumps straight to the message list" shortcut for
    /// exactly those callers, most of which drive the app from a *host*
    /// shell (`xcrun simctl launch`) with no way to synthesize a tap
    /// afterward and were never testing this specific navigation timing in
    /// the first place — see `SidebarView.observeMailboxes(accountId:)`'s
    /// doc comment for why this shortcut is otherwise gone by default.
    private var uiTestsShouldAutoAdvanceToContent: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestsAutoAdvanceToContent")
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            await startIdleLoops(for: environment.accounts)
            await syncAllAccountsOnce()
        case .background, .inactive:
            await environment.syncCoordinator.stopAllIdleLoops()
            // C7 「アプリを離脱したら即座に送信を確定」— cuts short whatever's
            // left of the countdown the instant the app leaves the
            // foreground, rather than letting it keep counting down
            // unobserved in the background (see `PendingSendCoordinator
            // .finalizeNow()`'s doc comment for why). A no-op if nothing is
            // currently pending.
            await environment.pendingSendCoordinator.finalizeNow()
        @unknown default:
            break
        }
    }

    private func startIdleLoops(for accounts: [AccountRecord]) async {
        for account in accounts {
            guard let auth = try? await environment.auth(for: account) else { continue }
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
            guard let auth = try? await environment.auth(for: account) else { continue }
            _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
            _ = try? await environment.syncCoordinator.syncAccountIncrementally(account, auth: auth)
        }
    }

    /// Same-session-only convenience: reopens whatever thread was last
    /// read under `selection` (e.g. switching from one mailbox to another
    /// and back) — see `lastOpenedThreadIdBySelectionKey`'s doc comment
    /// for why this can never fire on a cold launch (the dictionary starts
    /// empty every process, so there is structurally nothing to restore).
    /// Still guarded by `-uiTestsSkipThreadRestoration` for
    /// `scripts/verify-ios-m4.sh`'s foreground screenshot phases, which
    /// relaunch mid-script and don't want *this run's own* previously
    /// opened thread reappearing either — never set by the app itself,
    /// harmless in production since nothing else ever passes launch
    /// arguments.
    private func restoreLastOpenedThreadIfNeeded() {
        guard !ProcessInfo.processInfo.arguments.contains("-uiTestsSkipThreadRestoration") else { return }
        guard selectedThreadId == nil,
              let selection,
              let remembered = lastOpenedThreadIdBySelectionKey[selectionKey(for: selection)]
        else { return }
        selectedThreadId = remembered
        preferredColumn = .detail
    }

    /// `MessageListView.onThreadSelected`'s callback: records `threadId` as
    /// both the current detail selection and (keyed by `selectionUnder`)
    /// the "last opened thread" for same-session restoration, then
    /// unconditionally pushes `preferredColumn` forward to `.detail` — see
    /// `MessageListView.onThreadSelected`'s doc comment for why this must
    /// happen on *every* tap rather than only when `selectedThreadId`'s
    /// value actually changes.
    private func selectThread(_ threadId: Int64, under selectionUnder: SidebarSelection) {
        selectedThreadId = threadId
        lastOpenedThreadIdBySelectionKey[selectionKey(for: selectionUnder)] = threadId
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

    #if os(macOS)
    // MARK: - Menu commands (M10)

    /// ⌘R: replies to `selectedThreadId`'s newest message — the same
    /// message `ThreadDetailView` expands by default, so this matches
    /// "reply to whatever's currently showing expanded", not an arbitrary
    /// message within the thread.
    private func replyToSelectedThread() {
        guard let selectedThreadId else { return }
        Task {
            let messages = (try? await environment.database.dbWriter.read { db in
                try ThreadQuery.messages(threadId: selectedThreadId, db: db)
            }) ?? []
            guard let newestMessageId = messages.last?.id else { return }
            presentComposer(.reply(originalMessageId: newestMessageId, replyAll: false))
        }
    }

    /// ⌘⌫: moves every message in `selectedThreadId` to Trash — the same
    /// opQueue-enqueuing path `MessageListView.deleteThread(_:)` uses for
    /// its trailing swipe action, reimplemented here rather than shared
    /// because `MessageListView` doesn't currently expose that logic to a
    /// sibling view; both read from `ThreadQuery`/write through `OpQueue`
    /// the same way, so they can't drift in behavior even though the code
    /// isn't literally shared. Clears the selection afterward, same as a
    /// swipe-deleted row disappearing from the list would.
    private func deleteSelectedThread() {
        guard let selectedThreadId else { return }
        Task {
            do {
                let accountId: String? = try await environment.database.dbWriter.write { db -> String? in
                    let messages = try ThreadQuery.messages(threadId: selectedThreadId, db: db)
                    guard let thread = try ThreadRecord.fetchOne(db, key: selectedThreadId) else { return nil }
                    for message in messages {
                        guard let messageId = message.id, let uid = UInt32(exactly: message.uid) else { continue }
                        guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
                        try OpQueue.enqueueDelete(
                            accountId: thread.accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                            uids: [uid], db: db
                        )
                        try FTSIndexer.delete(messageId: messageId, db: db)
                        try MessageRecord.deleteOne(db, key: messageId)
                    }
                    try ThreadAssigner.recomputeAggregates(threadId: selectedThreadId, db: db)
                    return thread.accountId
                }
                self.selectedThreadId = nil
                guard let accountId, let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
                guard let auth = try? await environment.auth(for: account) else { return }
                _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
            } catch {
                // Best-effort, matching every other opQueue-enqueuing path
                // in this app — a failure here just means the thread stays.
            }
        }
    }

    /// ⌘]/⌘[: cycles `selection` through "すべての受信トレイ" followed by
    /// every account's mailboxes in the sidebar's own display order
    /// (`MailboxQuery.request`'s ordering — inbox-role first, then
    /// alphabetical), across every account in `environment.accounts` order.
    /// Wraps around at either end rather than stopping, matching what a
    /// "next/previous" pair of menu items conventionally does.
    private func cycleMailboxSelection(by direction: Int) {
        Task {
            var flattened: [SidebarSelection] = [.unifiedInbox]
            for account in environment.accounts {
                let mailboxes = (try? await environment.database.dbWriter.read { db in
                    try MailboxQuery.request(accountId: account.id).fetchAll(db)
                }) ?? []
                for mailbox in mailboxes {
                    guard let mailboxId = mailbox.id else { continue }
                    flattened.append(.mailbox(MailboxSelection(accountId: account.id, mailboxId: mailboxId)))
                }
            }
            guard !flattened.isEmpty else { return }
            let currentIndex = selection.flatMap { flattened.firstIndex(of: $0) }
            let nextIndex: Int
            if let currentIndex {
                nextIndex = (currentIndex + direction + flattened.count) % flattened.count
            } else {
                nextIndex = 0
            }
            selection = flattened[nextIndex]
        }
    }
    #endif
}

#Preview {
    RootView()
        .environment(AppEnvironment())
}
