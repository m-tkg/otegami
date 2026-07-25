import XCTest

/// Exploratory QA sweep (see `docs/qa-findings.md` and the task that
/// produced this file): mimics the kind of messy, non-scripted interaction
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
/// in `OtegamiColdLaunchAndSidebarSelectionUITests`: a cold relaunch lands
/// on the sidebar root, and `navigateToUnifiedInboxIfNeeded(in:)` is the
/// explicit, real tap that gets from there to the message list.
final class OtegamiQASweepUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Ensures the `test1` account exists (adding it, with the legacy
    /// auto-advance shortcut, only if genuinely starting from zero) and
    /// leaves the app on the message list — via a real tap through the
    /// sidebar root if that's where this process's own `app.launch()`
    /// landed (the normal case once an account already exists from an
    /// earlier test in this run).
    private func ensureDovecotTest1AccountExists(in app: XCUIApplication) {
        let emptyStateButton = app.buttons["sidebar.addAccountButton"]
        if emptyStateButton.waitForExistence(timeout: 5) {
            addDovecotTest1Account(in: app)
            restartAppToRecoverTouchDelivery(app)
        }
        // See the identical line in `OtegamiColdLaunchAndSidebarSelectionUITests`
        // for why this is required: `XCUIApplication.launchArguments`
        // persists across every `.launch()` on the same instance, so the
        // legacy `-uiTestsAutoAdvanceToContent` flag `restartAppToRecoverTouchDelivery`
        // sets above would otherwise leak into this test's own later *real*
        // kill/relaunch cycles, silently defeating the "must land on the
        // sidebar root, not auto-navigate" assertions those cycles make.
        app.launchArguments.removeAll { $0 == "-uiTestsAutoAdvanceToContent" }
        navigateToUnifiedInboxIfNeeded(in: app)
    }

    // MARK: - Scenario 1: messy kill/relaunch cycles from various screens

    /// Kills and relaunches the app 3x in a row from the plain message
    /// list, asserting each time that the sidebar root is reachable (the
    /// fixed cold-launch behavior — no auto-navigation into content) and,
    /// after tapping into the unified inbox, that its first row is
    /// tappable (not the "top row untappable" symptom from the cold-launch/
    /// livelock bug this project already found once).
    func testKillRestartCycleFromMessageList() throws {
        let app = XCUIApplication()
        app.launch()
        ensureDovecotTest1AccountExists(in: app)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        for cycle in 1...3 {
            app.terminate()
            app.launch()
            let sidebarList = app.collectionViews["sidebar.list"]
            XCTAssertTrue(sidebarList.waitForExistence(timeout: 20), "cycle \(cycle): sidebar root did not reappear after cold relaunch")
            XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "cycle \(cycle): message list not reachable after tapping the unified inbox row")
            let firstRow = list.cells.firstMatch
            XCTAssertTrue(firstRow.waitForExistence(timeout: 20), "cycle \(cycle): no rows in message list")
            // Confirm the top row is actually tappable (not just present) —
            // this is exactly the symptom the List(selection:) livelock bug
            // produced.
            firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
            let detailScroll = app.scrollViews["threadDetail.scrollView"]
            XCTAssertTrue(detailScroll.waitForExistence(timeout: 20), "cycle \(cycle): tapping the top row did not open a thread")
            // Pop back to the list before the next cycle's relaunch so we
            // don't accumulate state that changes what the *next* cold
            // launch would show.
            popBackOnceIfNeeded(in: app)
            XCTAssertTrue(list.waitForExistence(timeout: 10), "cycle \(cycle): could not return to the message list")
        }
    }

    /// Same kill/relaunch churn, but from inside an open thread detail
    /// each time (the exact screen the cold-launch restoration bug was
    /// triggered from) — confirms the fix holds up over repeated cycles,
    /// not just once, and that each relaunch lands on the sidebar root
    /// rather than resuming any pushed column.
    func testKillRestartCycleFromThreadDetail() throws {
        let app = XCUIApplication()
        app.launch()
        ensureDovecotTest1AccountExists(in: app)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        for cycle in 1...3 {
            let firstRow = list.cells.firstMatch
            XCTAssertTrue(waitForElementScrollingIfNeeded(firstRow, in: app), "cycle \(cycle): no row to open")
            firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
            let detailScroll = app.scrollViews["threadDetail.scrollView"]
            XCTAssertTrue(detailScroll.waitForExistence(timeout: 20), "cycle \(cycle): thread detail did not open")

            app.terminate()
            app.launch()

            // Cold relaunch must always land on the sidebar root, never
            // resume the detail pane (the originally-fixed bug) nor
            // auto-navigate into the message list (the follow-up bug).
            let sidebarList = app.collectionViews["sidebar.list"]
            XCTAssertTrue(sidebarList.waitForExistence(timeout: 20), "cycle \(cycle): relaunch did not land on the sidebar root")
            XCTAssertFalse(app.scrollViews["threadDetail.scrollView"].exists, "cycle \(cycle): relaunch incorrectly restored the thread detail pane")
            XCTAssertFalse(list.exists, "cycle \(cycle): relaunch incorrectly auto-navigated into the message list")

            XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "cycle \(cycle): could not navigate back into the message list for the next cycle")
        }
    }

    /// Kills and relaunches while the search field has text entered (but no
    /// submitted query) and while a search's empty-results state is
    /// showing — screens with transient, non-GRDB-backed state that a
    /// relaunch should just discard cleanly rather than getting stuck on.
    func testKillRestartCycleFromSearchInProgress() throws {
        let app = XCUIApplication()
        app.launch()
        ensureDovecotTest1AccountExists(in: app)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("zzzznotfound")

        // Give the FTS query a moment, then kill mid-search without
        // cancelling first — the messy-user case ("closed the app instead
        // of tapping Cancel").
        Thread.sleep(forTimeInterval: 2)
        app.terminate()
        app.launch()

        let sidebarList = app.collectionViews["sidebar.list"]
        XCTAssertTrue(sidebarList.waitForExistence(timeout: 20), "relaunch after killing mid-search did not land on the sidebar root")
        XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "relaunch after killing mid-search did not lead to a usable message list")
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
        ensureDovecotTest1AccountExists(in: app)
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
        XCTAssertTrue(app.scrollViews["threadDetail.scrollView"].waitForExistence(timeout: 20), "opening a thread after rapid mashing failed")
    }

    /// Rapidly switches between the unified inbox and an account's own
    /// INBOX in the sidebar, several times without waiting — the
    /// "統合トレイ⇄各 mailbox 高速切替" scenario, looking for a livelock
    /// variant of the already-fixed SidebarView List(selection:) bug.
    ///
    /// On this compact-width device, sidebar and content are never
    /// simultaneously on screen (a single-column push stack, not a
    /// side-by-side layout) — so "switching" necessarily means popping
    /// back to the sidebar and tapping the other row each time, re-querying
    /// the row fresh after every pop rather than reusing a cached
    /// `XCUIElement`/coordinate from before the previous forward push: a
    /// pushed-away sidebar row's coordinate can fail to resolve entirely
    /// ("Failed to get matching snapshot") once it's no longer the front-
    /// most screen, which is a fact about this navigation style, not
    /// itself the bug being tested for here.
    func testRapidSidebarMailboxSwitching() throws {
        let app = XCUIApplication()
        app.launch()
        ensureDovecotTest1AccountExists(in: app)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        let sidebarList = app.collectionViews["sidebar.list"]

        for i in 1...5 {
            returnToSidebarRootIfNeeded(in: app)
            XCTAssertTrue(sidebarList.waitForExistence(timeout: 10), "iteration \(i): sidebar not reachable")
            let inboxRow = sidebarList.cells.containing(NSPredicate(format: "label CONTAINS %@", "INBOX")).firstMatch
            XCTAssertTrue(inboxRow.waitForExistence(timeout: 10), "iteration \(i): INBOX row not found")
            inboxRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05)
            // No settle wait — immediately pop back and switch again.
            returnToSidebarRootIfNeeded(in: app)
            let unifiedRow = sidebarList.cells.containing(NSPredicate(format: "label CONTAINS %@", "すべての受信トレイ")).firstMatch
            XCTAssertTrue(unifiedRow.waitForExistence(timeout: 10), "iteration \(i): unified inbox row not found")
            unifiedRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05)
        }

        // After the mashing settles, the list must show real content, not
        // be stuck empty/loading forever (the livelock symptom).
        XCTAssertTrue(list.waitForExistence(timeout: 20), "message list pane did not reappear after rapid sidebar mailbox switching")
        let firstRow = list.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 25), "message list stayed empty after rapid sidebar mailbox switching (possible livelock)")
    }

    /// Types a search query, cancels immediately, types a different query —
    /// the "検索入力→即キャンセル→再入力" scenario.
    func testSearchTypeCancelRetype() throws {
        let app = XCUIApplication()
        app.launch()
        ensureDovecotTest1AccountExists(in: app)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("html")

        let cancelButton = app.buttons["Cancel"]
        if cancelButton.waitForExistence(timeout: 3) {
            cancelButton.tap()
        } else {
            // Some layouts use a system "Clear text" (x) button instead of
            // a text "Cancel" — try that, then dismiss the keyboard.
            let clearButton = searchField.buttons.firstMatch
            if clearButton.exists { clearButton.tap() }
            app.swipeDown()
        }

        XCTAssertTrue(list.waitForExistence(timeout: 10), "list did not reappear after cancelling search")

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

        let emptyStateButton = app.buttons["sidebar.addAccountButton"]
        if emptyStateButton.waitForExistence(timeout: 5) {
            openAccountSetup(in: app)
            fillDovecotAccountForm(in: app)
            runConnectionTest(in: app)
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

        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            searchField.typeText("a")
            app.swipeDown()
        }

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

        let emptyStateButton = app.buttons["sidebar.addAccountButton"]
        guard emptyStateButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("An account already exists from a previous test in this run; this scenario needs a clean zero-account start.")
        }

        addDovecotTest1Account(in: app)
        // No settle wait — add the second account immediately while the
        // first's initial sync is presumably still running.
        restartAppToRecoverTouchDelivery(app)
        returnToSidebarRootIfNeeded(in: app)
        addDovecotTest2Account(in: app)
        restartAppToRecoverTouchDelivery(app)

        returnToSidebarRootIfNeeded(in: app)
        let sidebarList = app.collectionViews["sidebar.list"]
        XCTAssertTrue(sidebarList.waitForExistence(timeout: 20))
        XCTAssertTrue(
            sidebarList.cells.containing(NSPredicate(format: "label CONTAINS %@", "Dovecot Test1")).firstMatch.waitForExistence(timeout: 10),
            "test1 account missing from sidebar after adding test2 immediately afterward"
        )
        XCTAssertTrue(
            sidebarList.cells.containing(NSPredicate(format: "label CONTAINS %@", "Dovecot Test2")).firstMatch.waitForExistence(timeout: 10),
            "test2 account missing from sidebar after being added immediately after test1"
        )

        // Both accounts' unified inbox should show real content, not an
        // empty list (the failure mode a corrupted partial sync would
        // produce, per docs/verify.md's thread-unassignment bug).
        let unifiedRow = sidebarList.cells.containing(NSPredicate(format: "label CONTAINS %@", "すべての受信トレイ")).firstMatch
        XCTAssertTrue(unifiedRow.waitForExistence(timeout: 10))
        unifiedRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))
        XCTAssertTrue(list.cells.firstMatch.waitForExistence(timeout: 20), "unified inbox stayed empty after adding two accounts back-to-back")
    }
}
