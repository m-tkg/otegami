import XCTest

/// Regression coverage for a cluster of real-device (iPhone 17 Pro, iOS 26)
/// UI bugs investigated in docs/verify.md's "実機バグ: アプリ kill→起動直後に
/// スレッド詳細へ勝手に遷移し、レイアウトが崩壊する" section, originally written
/// against the pre-design-phase-2 `NavigationSplitView`/`SidebarView`
/// structure (see this file's git history for the original doc comment).
/// Design-phase-2 replaced that whole navigation model on iOS with
/// `OtegamiRootView`'s tab bar + `MailScreenView`'s own `NavigationStack`
/// (`FolderListSheet` for mailbox selection, `.navigationDestination(item:)`
/// for thread detail) — several of the original bug *classes* this suite
/// existed to catch are now structurally impossible rather than merely
/// fixed (there is no `List(selection:)`/`@AppStorage`-restored selection
/// state left to oscillate or resurrect in the first place; see each test's
/// own doc comment for specifics), but the suite is kept and rewritten
/// rather than deleted — the underlying regressions it protects
/// (thread-detail layout collapse, a mailbox switch not populating, a
/// second tap not navigating) are still real risks worth a standing test
/// for, just expressed against the new structure.
final class OtegamiColdLaunchAndSidebarSelectionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Adds the dev mailstack's `test1` account only if genuinely starting
    /// from zero. This dev machine's `NSUbiquitousKeyValueStore`/Keychain
    /// sync through *real* iCloud rather than a simulator-scoped store
    /// (docs/verify.md's M11 section) — a previous verify run's account
    /// routinely resurrects itself even after a fresh `simctl uninstall`,
    /// so "does the empty state ever show up" isn't reliable to gate on.
    private func ensureDovecotTest1AccountExists(in app: XCUIApplication) {
        let emptyStateButton = app.buttons["mail.addAccountButton"]
        if emptyStateButton.waitForExistence(timeout: 5) {
            addDovecotTest1Account(in: app)
            restartAppToRecoverTouchDelivery(app, legacyAutoAdvanceToContent: false)
        }
    }

    /// The original bug: killing the app *while a thread is open* and
    /// relaunching used to restore straight into `ThreadDetailView` instead
    /// of the message list, and that view's `WKWebView`-backed body
    /// collapsed to near-zero height inside its own `ScrollView` (fixed by
    /// `ThreadDetailView.expandedMessageHeight(in:)`, unrelated to design-
    /// phase-2). The restoration half is now structurally impossible for
    /// iOS: `MailScreenView.selectedThreadId` is a plain `@State`, not
    /// `@AppStorage`, and there is no code path left that persists it
    /// across a process relaunch at all (`MailScreenView`'s doc comment). This
    /// test keeps the *layout* half as a live regression check (still a
    /// real risk, orthogonal to design-phase-2) and asserts the
    /// restoration half directly: after a real, unflagged cold relaunch,
    /// the Mail tab shows its message list, never a thread detail pane.
    func testColdRelaunchAfterOpeningAThreadStartsFromTheListNotTheDetail() throws {
        let app = XCUIApplication()
        app.launch()

        ensureDovecotTest1AccountExists(in: app)
        XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "Expected the message list to be reachable")
        let list = app.collectionViews["messageList.list"]

        // 16-cid-inline-image.eml — the exact seeded message matching the
        // user's original report ("インライン画像つき HTML メール").
        let subject = "インライン画像つきHTMLメール"
        let row = list.cells.containing(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
        XCTAssertTrue(waitForSeededSubjectScrollingIfNeeded(subject, in: app), "Expected the cid-inline-image seed message to appear")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        let detailScroll = app.scrollViews["threadDetail.scrollView"]
        XCTAssertTrue(detailScroll.waitForExistence(timeout: 20), "Expected the thread detail pane to open")

        // A genuine, unflagged relaunch — exercises real cold-launch
        // behavior end to end, same as the original bug report.
        app.terminate()
        app.launch()

        // Fixed behavior: a cold relaunch always starts on the Mail tab's
        // message list, never a restored thread detail pane.
        XCTAssertTrue(list.waitForExistence(timeout: 20), "Expected a cold relaunch to land on the Mail tab's message list")
        XCTAssertFalse(
            app.scrollViews["threadDetail.scrollView"].exists,
            "Expected no restored thread detail pane on a cold relaunch"
        )

        // The reported "top row untappable" symptom: tap the very first
        // row and confirm the detail pane actually opens. (Whichever
        // thread happens to sort first isn't asserted by subject — the dev
        // mailstack accumulates extra messages across verify runs,
        // docs/verify.md's note on state persisting across milestones —
        // only that tapping it works and opens something real.)
        let firstRow = list.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20), "Expected at least one row in the message list")
        firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        XCTAssertTrue(detailScroll.waitForExistence(timeout: 20), "Expected tapping the top row to open its thread detail")

        // The reported layout-collapse symptom: the expanded message's
        // header row (always mounted once a message is expanded,
        // regardless of whether its body is HTML or plain text) should sit
        // near the *top* of the detail pane, not pushed down behind a
        // large block of empty space by `.defaultScrollAnchor(.bottom)`
        // combined with a collapsed-to-near-zero body height.
        let expandedHeader = detailScroll.buttons
            .matching(NSPredicate(format: "identifier CONTAINS %@", "threadDetail.message."))
            .matching(NSPredicate(format: "identifier CONTAINS %@", ".header"))
            .firstMatch
        XCTAssertTrue(expandedHeader.waitForExistence(timeout: 20), "Expected at least one message header to mount in the thread detail pane")
        XCTAssertLessThan(
            expandedHeader.frame.minY, detailScroll.frame.height * 0.5,
            "Expected the topmost message header to sit in the upper half of the screen, not pushed down behind a block of empty space (header y=\(expandedHeader.frame.minY), screen height=\(detailScroll.frame.height))"
        )

        // Hold the thread open for a wrapping shell script's mid-test
        // screenshot, for visual review alongside the geometric assertion
        // above (same technique as M6/M8/M4's thread-detail phase).
        Thread.sleep(forTimeInterval: 4)
    }

    /// The original "サイドバー → INBOX をタップすると一覧に何も出ない" symptom,
    /// rewritten against `FolderListSheet` (1a's folder-picker sheet,
    /// design-phase-2's replacement for the always-visible sidebar): open
    /// the sheet via the Mail tab's tappable title, tap a specific
    /// account's own INBOX mailbox row (not the unified inbox, which is
    /// already selected by default and so wouldn't exercise a mailbox
    /// *switch*), and confirm the list actually switches to (and populates
    /// from) that mailbox.
    func testTappingAMailboxRowInTheFolderSheetPopulatesItsMessageList() throws {
        let app = XCUIApplication()
        app.launch()

        ensureDovecotTest1AccountExists(in: app)
        XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "Expected the message list to be reachable")
        let list = app.collectionViews["messageList.list"]

        app.buttons["mail.hamburgerButton"].tap()
        let folderList = app.collectionViews["folderSheet.list"]
        XCTAssertTrue(folderList.waitForExistence(timeout: 20), "Expected the folder sheet to appear")

        let inboxRow = folderList.cells.containing(NSPredicate(format: "label CONTAINS %@", "INBOX")).firstMatch
        XCTAssertTrue(inboxRow.waitForExistence(timeout: 20), "Expected an INBOX mailbox row in the folder sheet")
        inboxRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        XCTAssertTrue(list.waitForExistence(timeout: 20), "Expected tapping the INBOX row to dismiss the sheet and show the message list")
        let firstRow = list.cells.firstMatch
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 20),
            "Expected the INBOX mailbox's message list to populate after selecting it in the folder sheet, not stay empty"
        )
    }

    /// The original bug 3 (auto-select of the unified inbox pushing the
    /// compact-width column forward on every launch) doesn't have an iOS
    /// equivalent to regress against anymore — the Mail tab *is* the
    /// message list, by design, with no intermediate "root" screen to skip
    /// past. This test instead pins the current, intended behavior as a
    /// smoke check: a cold relaunch with an existing account shows the Mail
    /// tab's message list directly, already populated, with no extra tap
    /// and no stuck loading/empty state.
    func testColdRelaunchWithExistingAccountLandsOnTheMailTabMessageList() throws {
        let app = XCUIApplication()
        app.launch()
        ensureDovecotTest1AccountExists(in: app)

        app.terminate()
        app.launch()

        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20), "Expected a cold relaunch to land directly on the Mail tab's message list")
        XCTAssertTrue(
            list.cells.firstMatch.waitForExistence(timeout: 20),
            "Expected the message list to already be populated on a cold relaunch, not stuck empty"
        )
    }

    /// The original bug 4 (re-tapping the sidebar row for the
    /// already-selected value never re-fired the compact-width column push,
    /// since `List(selection:)`'s value hadn't changed) doesn't have a
    /// direct iOS equivalent either: `FolderListSheet`'s rows call
    /// `MailScreenView.selectUnifiedInbox()`/`selectMailbox(_:_:)` directly,
    /// which unconditionally dismiss the sheet regardless of whether the
    /// selection's *value* actually changed — there's no diff-based
    /// `onChange` left in this path to fail to fire. This test instead
    /// confirms that directly: open the folder sheet, re-select the same
    /// (already-active) unified inbox, and confirm the sheet dismisses back
    /// to a populated message list rather than getting stuck.
    func testReselectingTheAlreadyActiveFolderStillDismissesTheSheet() throws {
        let app = XCUIApplication()
        app.launch()
        ensureDovecotTest1AccountExists(in: app)
        XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "Expected the message list to be reachable")
        let list = app.collectionViews["messageList.list"]

        app.buttons["mail.hamburgerButton"].tap()
        let folderList = app.collectionViews["folderSheet.list"]
        XCTAssertTrue(folderList.waitForExistence(timeout: 20))

        let unifiedRow = folderList.cells.containing(NSPredicate(format: "label CONTAINS %@", "すべての受信トレイ")).firstMatch
        XCTAssertTrue(unifiedRow.waitForExistence(timeout: 10))
        unifiedRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        XCTAssertTrue(
            list.waitForExistence(timeout: 20),
            "Expected re-selecting the already-active unified inbox to still dismiss the sheet back to a populated message list"
        )
        XCTAssertTrue(list.cells.firstMatch.waitForExistence(timeout: 20), "Expected the message list to still be populated")
    }

    /// Bug 4's thread variant, still fully applicable: open a thread → back
    /// → tap the *same* row again → the detail pane must reopen, not stay
    /// stuck on the list. `MailScreenView` drives this via
    /// `.navigationDestination(item: $selectedThreadId)`; popping back via
    /// the system back button resets that binding to `nil` (SwiftUI's own
    /// `NavigationStack` behavior), so re-tapping the same row is a genuine
    /// nil→value transition each time — this test pins that framework
    /// behavior as a regression guard, the same real risk the original
    /// `List(selection:)`-based version guarded against.
    func testRetappingTheSameMessageRowAfterPoppingBackNavigatesAgain() throws {
        let app = XCUIApplication()
        app.launch()
        ensureDovecotTest1AccountExists(in: app)
        XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "Expected the message list to be reachable")
        let list = app.collectionViews["messageList.list"]

        let row = list.cells.firstMatch
        XCTAssertTrue(waitForElementScrollingIfNeeded(row, in: app), "Expected at least one row to open")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        let detailScroll = app.scrollViews["threadDetail.scrollView"]
        XCTAssertTrue(detailScroll.waitForExistence(timeout: 20), "Expected the first tap to open the thread detail")

        popBackOnceIfNeeded(in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 20), "Expected popping back to return to the message list")

        // Same row, same underlying thread id — re-tap it.
        let sameRow = list.cells.firstMatch
        XCTAssertTrue(sameRow.waitForExistence(timeout: 10))
        sameRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        XCTAssertTrue(
            detailScroll.waitForExistence(timeout: 20),
            "Expected re-tapping the same message row after popping back to reopen its thread detail, not stay stuck on the list"
        )
    }
}
