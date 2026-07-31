import XCTest

/// Exploratory QA sweep: mimics the kind of messy, non-scripted interaction
/// sequences that surfaced the four real-device bugs documented in
/// `docs/verify.md` (VoIP socket, partial-sync thread-unassignment,
/// empty-refetch mass-delete, cold-launch restoration/livelock) — all of
/// which passed every existing XCUITest happy-path before they were found
/// on a real device. These tests intentionally hammer kill/relaunch cycles
/// and rapid screen/selection changes rather than a single deterministic
/// path, on the theory that another bug in the same family (a `Task`
/// racing a view teardown, a `List(selection:)`-style binding glitch, a
/// sync loop not tolerating being interrupted) is more likely to show up
/// under that kind of churn than under a scripted single pass.
///
/// None of these tests use `-uiTestsAutoAdvanceToContent` — every relaunch
/// below is a genuine, unflagged cold launch, so each one also doubles as
/// extra churn-testing of the real (fixed) navigation behavior documented
/// in `OtegamiColdLaunchAndSidebarSelectionUITests`. Design-phase-2: a cold
/// relaunch now lands directly on the Mail tab's message list (there is no
/// separate "sidebar root" screen to tap through anymore — see that file's
/// doc comment), so `navigateToUnifiedInboxIfNeeded(in:)` below is mostly a
/// defensive existence check rather than the real navigating tap it used to
/// be.
final class OtegamiQASweepUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Ensures the `test1` account exists (adding it, with the legacy
    /// auto-advance shortcut, only if genuinely starting from zero) and
    /// leaves the app on the Mail tab's message list — reachable directly
    /// once an account exists (design-phase-2: no sidebar root to tap
    /// through anymore).
    private func ensureDovecotTest1AccountExists(in app: XCUIApplication) throws {
        let emptyStateButton = app.buttons["mail.addAccountButton"]
        if emptyStateButton.waitForExistence(timeout: 5) {
            try addDovecotTest1Account(in: app)
            restartAppToRecoverTouchDelivery(app)
        }
        // See the identical line in `OtegamiColdLaunchAndSidebarSelectionUITests`
        // for why this is required: `XCUIApplication.launchArguments`
        // persists across every `.launch()` on the same instance, so the
        // legacy `-uiTestsAutoAdvanceToContent` flag `restartAppToRecoverTouchDelivery`
        // sets above would otherwise leak into this test's own later *real*
        // kill/relaunch cycles — harmless for iOS's Mail-tab-first structure
        // specifically, but still worth clearing so these tests exercise the
        // actual unflagged cold-launch path.
        app.launchArguments.removeAll { $0 == "-uiTestsAutoAdvanceToContent" }
        navigateToUnifiedInboxIfNeeded(in: app)
    }

    // MARK: - Scenario 1: messy kill/relaunch cycles from various screens

    /// Kills and relaunches the app 3x in a row from the plain message
    /// list, asserting each time that the Mail tab's message list is
    /// reachable directly (the fixed cold-launch behavior — no stuck
    /// loading/empty state) and that its first row is tappable (not the
    /// "top row untappable" symptom from the cold-launch/livelock bug this
    /// project already found once).
    func testKillRestartCycleFromMessageList() throws {
        let app = XCUIApplication()
        app.launch()
        try ensureDovecotTest1AccountExists(in: app)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        for cycle in 1...3 {
            app.terminate()
            app.launch()
            XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "cycle \(cycle): message list did not reappear after cold relaunch")
            let firstRow = list.cells.firstMatch
            XCTAssertTrue(firstRow.waitForExistence(timeout: 20), "cycle \(cycle): no rows in message list")
            // Confirm the top row is actually tappable (not just present) —
            // this is exactly the symptom the List(selection:) livelock bug
            // produced.
            firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
            // Task #136: see `waitForThreadDetailPossiblyThroughSelectionScreen`'s
            // doc comment — opens straight into the accordion now.
            XCTAssertTrue(waitForThreadDetailPossiblyThroughSelectionScreen(in: app), "cycle \(cycle): tapping the top row did not open a thread")
            // Pop back to the list before the next cycle's relaunch so we
            // don't accumulate state that changes what the *next* cold
            // launch would show.
            returnToMailTabRootIfNeeded(in: app)
            XCTAssertTrue(list.waitForExistence(timeout: 10), "cycle \(cycle): could not return to the message list")
        }
    }

    /// Same kill/relaunch churn, but from inside an open thread detail
    /// each time (the exact screen the cold-launch restoration bug was
    /// triggered from) — confirms the fix holds up over repeated cycles,
    /// not just once. Design-phase-2: there's no `@AppStorage`-restored
    /// selection left at all for iOS (`MailScreenView.selectedThreadId` is a
    /// plain `@State`), so this now asserts the message list reappears
    /// directly and the detail pane is never resumed.
    func testKillRestartCycleFromThreadDetail() throws {
        let app = XCUIApplication()
        app.launch()
        try ensureDovecotTest1AccountExists(in: app)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        for cycle in 1...3 {
            let firstRow = list.cells.firstMatch
            XCTAssertTrue(waitForElementScrollingIfNeeded(firstRow, in: app), "cycle \(cycle): no row to open")
            firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
            XCTAssertTrue(waitForThreadDetailPossiblyThroughSelectionScreen(in: app), "cycle \(cycle): thread detail did not open")

            app.terminate()
            app.launch()

            // Cold relaunch must always land on the message list directly,
            // never resume the detail pane (the originally-fixed bug).
            XCTAssertTrue(list.waitForExistence(timeout: 20), "cycle \(cycle): relaunch did not show the message list")
            XCTAssertFalse(app.scrollViews["threadDetail.scrollView"].exists, "cycle \(cycle): relaunch incorrectly restored the thread detail pane")
        }
    }

    /// Kills and relaunches while `SearchScreenView`'s sheet has text
    /// entered (but no submitted query) — 新画面構成: search is a sheet
    /// opened from `MailScreenView`'s header button now, not its own tab, so
    /// "mid-search" means "the search sheet open with in-flight text," not a
    /// state on the message list screen itself. Transient, non-GRDB-backed
    /// state either way — a relaunch should discard it cleanly (the sheet
    /// isn't restored, back to the plain message list) rather than getting
    /// stuck.
    func testKillRestartCycleFromSearchInProgress() throws {
        let app = XCUIApplication()
        app.launch()
        try ensureDovecotTest1AccountExists(in: app)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        openSearchScreen(in: app)
        let searchField = app.textFields["search.textField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("zzzznotfound")

        // Give the FTS query a moment, then kill mid-search without
        // cancelling first — the messy-user case ("closed the app instead
        // of tapping Cancel").
        Thread.sleep(forTimeInterval: 2)
        app.terminate()
        app.launch()

        XCTAssertTrue(list.waitForExistence(timeout: 20), "relaunch after killing mid-search did not land on the Mail tab's message list")
        let firstRow = list.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20), "relaunch after killing mid-search left the message list empty")
    }

    // MARK: - Scenario 2: rapid screen-transition mashing

    /// Rapidly opens a thread and immediately pops back, several times in a
    /// row, without waiting for any settling — the "open→back→open→back"
    /// mash from the task's scenario list, looking for a livelock variant
    /// where a fast pop cancels the row tap's own state update.
    func testRapidOpenAndBackMashing() throws {
        let app = XCUIApplication()
        app.launch()
        try ensureDovecotTest1AccountExists(in: app)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        for i in 1...6 {
            let row = list.cells.element(boundBy: 0)
            XCTAssertTrue(waitForElementScrollingIfNeeded(row, in: app), "mash \(i): no row available")
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05)
            // No settle wait on purpose — mash immediately.
            let backButton = app.navigationBars.buttons.element(boundBy: 0)
            if backButton.waitForExistence(timeout: 5) {
                backButton.tap()
            }
        }

        // After the mashing, the app must still be in a genuinely usable
        // state: list visible, top row tappable, opens successfully.
        XCTAssertTrue(list.waitForExistence(timeout: 20), "message list did not settle after rapid open/back mashing")
        let finalRow = list.cells.firstMatch
        XCTAssertTrue(finalRow.waitForExistence(timeout: 20))
        finalRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        XCTAssertTrue(waitForThreadDetailPossiblyThroughSelectionScreen(in: app), "opening a thread after rapid mashing failed")
    }

    /// Rapidly switches between the unified inbox and an account's own
    /// INBOX via `FolderListSheet`, several times without waiting — the
    /// "統合トレイ⇄各 mailbox 高速切替" scenario, looking for a livelock
    /// variant of the already-fixed `SidebarView` `List(selection:)` bug
    /// (design-phase-2: the folder picker moved into a sheet, but the same
    /// underlying "does rapidly re-driving the selection ever get the list
    /// stuck" risk still applies to `MailScreenView.mailSelection`).
    func testRapidMailboxSwitchingViaFolderSheet() throws {
        let app = XCUIApplication()
        app.launch()
        try ensureDovecotTest1AccountExists(in: app)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        let folderTitleButton = app.buttons["mail.hamburgerButton"]
        let folderList = app.collectionViews["folderSheet.list"]

        for i in 1...5 {
            folderTitleButton.tap()
            XCTAssertTrue(folderList.waitForExistence(timeout: 10), "iteration \(i): folder sheet not reachable")
            let inboxRow = folderList.cells.containing(NSPredicate(format: "label CONTAINS %@", "INBOX")).firstMatch
            XCTAssertTrue(inboxRow.waitForExistence(timeout: 10), "iteration \(i): INBOX row not found")
            inboxRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05)
            // No settle wait — immediately reopen the sheet and switch back.
            folderTitleButton.tap()
            XCTAssertTrue(folderList.waitForExistence(timeout: 10), "iteration \(i): folder sheet not reachable (second open)")
            let unifiedRow = folderList.cells.containing(NSPredicate(format: "label CONTAINS %@", "すべての受信トレイ")).firstMatch
            XCTAssertTrue(unifiedRow.waitForExistence(timeout: 10), "iteration \(i): unified inbox row not found")
            unifiedRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05)
        }

        // After the mashing settles, the list must show real content, not
        // be stuck empty/loading forever (the livelock symptom).
        XCTAssertTrue(list.waitForExistence(timeout: 20), "message list pane did not reappear after rapid mailbox switching")
        let firstRow = list.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 25), "message list stayed empty after rapid mailbox switching (possible livelock)")
    }

    /// Types a search query, cancels immediately, types a different query —
    /// the "検索入力→即キャンセル→再入力" scenario. 新画面構成: exercised inside
    /// `SearchScreenView`'s sheet now, not the Mail tab's list.
    func testSearchTypeCancelRetype() throws {
        let app = XCUIApplication()
        app.launch()
        try ensureDovecotTest1AccountExists(in: app)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        openSearchScreen(in: app)
        let searchField = app.textFields["search.textField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("html")

        // 検索画面再構成 (Task #86): システムの`.searchable`が持っていた
        // 「Cancel」ボタン/「Clear text」(x) は無くなった (`SearchTopBar`は
        // 独自の`TextField`——閉じるボタンは画面全体を閉じる方の導線なので
        // ここでは使わない) — backspaceで打ち消してから同じ画面内で打ち
        // 直す、という「入力→即取り消し→再入力」の意図はそのまま
        // backspaceキー送出で再現する。
        searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "html".count))
        app.swipeDown()

        let searchList = app.collectionViews["search.list"]
        XCTAssertTrue(searchList.waitForExistence(timeout: 10), "search list did not reappear after cancelling search")

        searchField.tap()
        searchField.typeText("打ち")
        Thread.sleep(forTimeInterval: 3)

        // Whatever the outcome (results or empty state), the app must not
        // be stuck on neither — some recognizable content should exist.
        let anyResult = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "打ち")).firstMatch
        let emptyState = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No Results")).firstMatch
        XCTAssertTrue(anyResult.waitForExistence(timeout: 10) || emptyState.exists, "search re-entry after cancel produced neither results nor an empty state")
    }

    // MARK: - Scenario 3: operating while sync is in flight

    /// Adds the account and, without waiting for initial sync to visibly
    /// settle, immediately scrolls the list and opens the search field —
    /// the "初期同期の最中に一覧スクロール・検索を開く" scenario. Mostly a
    /// crash/hang smoke test since the exact in-flight state is racy by
    /// nature.
    func testInteractDuringInitialSync() throws {
        let app = XCUIApplication()
        app.launch()

        let emptyStateButton = app.buttons["mail.addAccountButton"]
        if emptyStateButton.waitForExistence(timeout: 5) {
            openAccountSetup(in: app)
            fillDovecotAccountForm(in: app)
            try runConnectionTest(in: app)
            saveAccount(in: app)
            // Deliberately do NOT wait for sync to settle — interact
            // immediately while it's still in flight. The post-save state
            // is still subject to the M2 "{-1,-1} touch delivery" defect
            // until a restart, so recover that first (this is about
            // exercising in-flight sync, not re-litigating that
            // environment quirk) — the legacy auto-advance flag gets us
            // straight to the message list, exactly when sync would still
            // plausibly be running.
            restartAppToRecoverTouchDelivery(app)
        } else {
            // Account already exists from a previous test in this run;
            // that's fine, this scenario just needs *some* sync activity
            // in flight, which a cold app launch's foreground sync always
            // triggers regardless. Navigate to the message list for real
            // since this launch had no legacy flag.
            navigateToUnifiedInboxIfNeeded(in: app)
        }

        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20), "message list never became reachable while sync was starting")

        // Scroll immediately, before any settle wait.
        list.swipeUp()
        list.swipeDown()

        // 新画面構成: search opens as a sheet from the header button now.
        openSearchScreen(in: app)
        let searchField = app.textFields["search.textField"]
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            searchField.typeText("a")
            app.swipeDown()
        }
        closeSearchScreen(in: app)

        // The app must still be responsive and eventually show the seeded
        // baseline once sync actually completes.
        XCTAssertTrue(waitForSeededSubjectScrollingIfNeeded("ようこそ otegami へ", in: app, maxScrollAttempts: 15), "seeded baseline message never appeared even after interacting during initial sync")
    }

    /// Adds a second account while the first account's sync/IDLE machinery
    /// is presumably still warming up, then confirms both accounts end up
    /// usable — the "2 アカウント目追加中に 1 アカウント目を操作" scenario
    /// (approximated: XCUITest can't truly interleave with async sync
    /// timing, so this instead checks that adding account 2 immediately
    /// after account 1, without any settle delay, doesn't corrupt either
    /// account's state).
    func testAddSecondAccountImmediatelyAfterFirst() throws {
        let app = XCUIApplication()
        app.launch()

        let emptyStateButton = app.buttons["mail.addAccountButton"]
        guard emptyStateButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("An account already exists from a previous test in this run; this scenario needs a clean zero-account start.")
        }

        try addDovecotTest1Account(in: app)
        // No settle wait — add the second account immediately while the
        // first's initial sync is presumably still running.
        restartAppToRecoverTouchDelivery(app)
        returnToMailTabRootIfNeeded(in: app)
        try addDovecotTest2Account(in: app)
        restartAppToRecoverTouchDelivery(app)

        // Both accounts should be present — design-phase-2: checked via
        // `FolderListSheet` (each account gets its own `Section`) rather
        // than the old always-visible sidebar.
        returnToMailTabRootIfNeeded(in: app)
        app.buttons["mail.hamburgerButton"].tap()
        let folderList = app.collectionViews["folderSheet.list"]
        XCTAssertTrue(folderList.waitForExistence(timeout: 20))
        XCTAssertTrue(
            folderList.cells.containing(NSPredicate(format: "label CONTAINS %@", "Dovecot Test1")).firstMatch.waitForExistence(timeout: 10),
            "test1 account missing from the folder sheet after adding test2 immediately afterward"
        )
        XCTAssertTrue(
            folderList.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Dovecot Test2")).firstMatch.waitForExistence(timeout: 10),
            "test2 account missing from the folder sheet after being added immediately after test1"
        )

        // Both accounts' unified inbox should show real content, not an
        // empty list (the failure mode a corrupted partial sync would
        // produce, per docs/verify.md's thread-unassignment bug).
        let unifiedRow = folderList.cells.containing(NSPredicate(format: "label CONTAINS %@", "すべての受信トレイ")).firstMatch
        XCTAssertTrue(unifiedRow.waitForExistence(timeout: 10))
        unifiedRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))
        XCTAssertTrue(list.cells.firstMatch.waitForExistence(timeout: 20), "unified inbox stayed empty after adding two accounts back-to-back")
    }
}
