import XCTest

/// Regression coverage for a cluster of real-device (iPhone 17 Pro, iOS 26)
/// UI bugs investigated in docs/verify.md's "実機バグ: アプリ kill→起動直後に
/// スレッド詳細へ勝手に遷移し、レイアウトが崩壊する" section — all traced back to
/// two root causes in `OtegamiApp.swift`/`SidebarView.swift`, not four
/// unrelated bugs:
///
/// 1. `RootView`'s "last opened thread" restoration used to persist across
///    a cold app launch (`@AppStorage`) and — because `SidebarView`'s
///    `List(selection:)` binding oscillates `selection` through `nil` and
///    back while the account/mailbox list is still loading in, not just
///    settling once — could restore on a *later* oscillation within the
///    very same cold launch even after an attempted "skip the first call"
///    guard. Fixed by making the remembered thread same-session-only
///    (`OtegamiApp.lastOpenedThreadIdBySelectionKey`, plain `@State`, not
///    `@AppStorage`): a cold launch has nothing to restore *from* no
///    matter how `selection` churns during startup.
/// 2. `ThreadDetailView` embeds each expanded `MessageView`/
///    `HTMLMessageView` — designed to fill whatever bounded height its
///    parent proposes (M2, when it was the sole content of the `detail`
///    column) — inside its own `ScrollView`/`LazyVStack` (M4), which
///    proposes an *unbounded* height along its scroll axis. A `WKWebView`
///    with no intrinsic content size collapsed to near-zero there, and
///    `.defaultScrollAnchor(.bottom)` then pinned the whole (much-shorter-
///    than-the-screen) thread to the bottom, leaving a large empty block
///    above. Fixed by sizing the expanded row off the container's own
///    measured height (`ThreadDetailView.expandedMessageHeight(in:)`).
///
/// The reported "top row untappable" and "サイドバー → INBOX をタップすると
/// 一覧に何も出ない" symptoms turned out to be two more faces of the *same*
/// `List(selection:)` instability as (1) — already flagged as flaky in this
/// project's environment for `MessageListView` (M2's pitfall #2,
/// `.claude/skills/verify/SKILL.md`), but `SidebarView` was never migrated
/// off it. Confirmed empirically: tapping a `List(selection:)`-tagged
/// sidebar row could tear `MessageListView` down and rebuild it faster than
/// its first `ValueObservation` fetch could ever complete — a livelock that
/// never resolved on its own, not a one-time glitch. Fixed by converting
/// `SidebarView`'s selection-driving rows from `List(selection:)`/`.tag()`
/// to explicit `Button { selection = ... }` actions, the same pattern
/// `MessageListView`'s own rows already used for the identical reason.
///
/// A follow-up QA sweep (see docs/qa-findings.md) found two *more* bugs in
/// the same family, both still about `RootView`'s `preferredCompactColumn`
/// not tracking what the user actually did:
///
/// 3. Fixing (1)/the livelock above didn't remove the *data*-level
///    auto-select of `.unifiedInbox` the instant the first account's
///    mailboxes load (`SidebarView.observeMailboxes(accountId:)`) — and
///    `RootView` used to push `preferredColumn` forward on *any*
///    `selection` becoming non-`nil`, including that background auto-select.
///    On a compact-width device that meant *every* app launch with an
///    existing account skipped the sidebar root entirely and landed
///    straight on the message list — "コールドランチが統合受信トレイから
///    始まる". Fixed by making the auto-select data-only (no column push);
///    only a real row tap pushes the column now.
/// 4. Re-tapping the row for whatever's *already* the current selection
///    (e.g. unified inbox → back → unified inbox again, or a thread →
///    back → the same thread again) doesn't change the underlying
///    `selection`/`selectedThreadId` value, so the `onChange`-driven column
///    push that both used to rely on simply never fired a second time —
///    "「直前に選択していた行」だけタップ不能". Fixed by pushing the column
///    forward from an explicit, unconditional callback fired on every row
///    tap (`SidebarView.onSelected`/`MessageListView.onThreadSelected`)
///    instead of deriving it from the selection value's own before/after
///    diff.
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
    /// Uses the legacy auto-advance shortcut for this setup step only —
    /// the tests below each do their own *real*, unflagged relaunch/tap to
    /// exercise the actual fixed behavior.
    private func ensureDovecotTest1AccountExists(in app: XCUIApplication) {
        let emptyStateButton = app.buttons["sidebar.addAccountButton"]
        if emptyStateButton.waitForExistence(timeout: 5) {
            addDovecotTest1Account(in: app)
            restartAppToRecoverTouchDelivery(app)
        }
        // `XCUIApplication.launchArguments` persists across every `.launch()`
        // call on the same instance, not just the one it was set before —
        // confirmed empirically (a real, reproducible failure caught while
        // building this suite, not a hypothetical): `restartAppToRecoverTouchDelivery`
        // above appends `-uiTestsAutoAdvanceToContent` for its own relaunch,
        // and without this line that flag silently leaked into every test
        // method's *own* later "real" `app.terminate(); app.launch()` calls
        // below, defeating the entire point of testing the unflagged cold-
        // launch behavior (the relaunch would auto-advance into the message
        // list again, exactly like the bug this suite exists to catch).
        // Only reproduces when this branch actually ran (a fresh account had
        // to be created) — skipped entirely when an account already existed
        // from an earlier test in the same run, which is why this was easy
        // to miss on a quick spot-check but failed reliably on a clean
        // `simctl erase`.
        app.launchArguments.removeAll { $0 == "-uiTestsAutoAdvanceToContent" }
    }

    func testColdRelaunchAfterOpeningAThreadStartsFromTheListNotTheDetail() throws {
        let app = XCUIApplication()
        app.launch()

        ensureDovecotTest1AccountExists(in: app)
        XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "Expected the message list to be reachable")
        let list = app.collectionViews["messageList.list"]

        // 16-cid-inline-image.eml — the exact seeded message matching the
        // user's report ("インライン画像つき HTML メール").
        let subject = "インライン画像つきHTMLメール"
        let row = list.cells.containing(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
        XCTAssertTrue(waitForSeededSubjectScrollingIfNeeded(subject, in: app), "Expected the cid-inline-image seed message to appear")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        let detailScroll = app.scrollViews["threadDetail.scrollView"]
        XCTAssertTrue(detailScroll.waitForExistence(timeout: 20), "Expected the thread detail pane to open")

        // The bug: killing the app *while a thread is open* and relaunching
        // used to restore straight into this same detail pane instead of
        // the list. This is a genuine, unflagged relaunch — no
        // `-uiTestsAutoAdvanceToContent` — exercising real cold-launch
        // behavior end to end.
        app.terminate()
        app.launch()

        // Fixed behavior (bug 3, above): a cold relaunch always starts from
        // the sidebar root, not the message list and certainly not the
        // detail pane — no tap should be needed to prove that nothing
        // auto-navigated anywhere.
        let sidebarList = app.collectionViews["sidebar.list"]
        XCTAssertTrue(sidebarList.waitForExistence(timeout: 20), "Expected a cold relaunch to land on the sidebar root, not any pushed column")
        XCTAssertFalse(list.exists, "Expected no auto-navigation into the message list on a cold relaunch — the sidebar root should be the very first thing shown")
        XCTAssertFalse(
            app.scrollViews["threadDetail.scrollView"].exists,
            "Expected no restored thread detail pane on a cold relaunch — the app should come up on the sidebar root only"
        )

        // Now navigate in for real, the way an actual user would: tap
        // "すべての受信トレイ".
        XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "Expected tapping the unified inbox row to reach the message list")

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

    /// The reported "サイドバー → INBOX をタップすると一覧に何も出ない" symptom:
    /// pop back to the sidebar and tap a specific account's own INBOX
    /// mailbox row (not "すべての受信トレイ", which a cold launch already
    /// selects by default and so wouldn't actually exercise a mailbox
    /// *switch*) and confirm the list actually switches to (and populates
    /// from) that mailbox.
    func testTappingAMailboxRowInTheSidebarPopulatesItsMessageList() throws {
        let app = XCUIApplication()
        app.launch()

        ensureDovecotTest1AccountExists(in: app)
        XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "Expected the message list to be reachable")
        let list = app.collectionViews["messageList.list"]

        // Back out to the sidebar — `returnToSidebarRootIfNeeded` pops
        // however many levels deep a fresh launch happened to land at.
        returnToSidebarRootIfNeeded(in: app)
        let sidebarList = app.collectionViews["sidebar.list"]
        XCTAssertTrue(sidebarList.waitForExistence(timeout: 20), "Expected the sidebar to be reachable")

        let inboxRow = sidebarList.cells.containing(NSPredicate(format: "label CONTAINS %@", "INBOX")).firstMatch
        XCTAssertTrue(inboxRow.waitForExistence(timeout: 20), "Expected an INBOX mailbox row in the sidebar")
        inboxRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        XCTAssertTrue(list.waitForExistence(timeout: 20), "Expected tapping the INBOX row to navigate to the message list")
        let firstRow = list.cells.firstMatch
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 20),
            "Expected the INBOX mailbox's message list to populate after tapping it in the sidebar, not stay empty"
        )
    }

    /// Bug 3 (above), asserted directly rather than as a side effect of the
    /// thread-detail test: a cold relaunch with an *existing* account lands
    /// on the sidebar root, with neither the message list nor any account's
    /// mailbox tree collapsed away underneath it — the user should always
    /// have to make one deliberate tap to reach their mail.
    func testColdRelaunchWithExistingAccountLandsOnSidebarRoot() throws {
        let app = XCUIApplication()
        app.launch()
        ensureDovecotTest1AccountExists(in: app)
        // Get back to a known state (sidebar root) before the real test
        // relaunch below.
        returnToSidebarRootIfNeeded(in: app)

        app.terminate()
        app.launch()

        let sidebarList = app.collectionViews["sidebar.list"]
        XCTAssertTrue(sidebarList.waitForExistence(timeout: 20), "Expected a cold relaunch to land on the sidebar root")
        XCTAssertFalse(app.collectionViews["messageList.list"].exists, "Expected the message list not to be auto-navigated to on a cold relaunch")
        // The sidebar itself should already be usable (accounts loaded),
        // not stuck on a permanent loading/empty state.
        let unifiedRow = sidebarList.cells.containing(NSPredicate(format: "label CONTAINS %@", "すべての受信トレイ")).firstMatch
        XCTAssertTrue(unifiedRow.waitForExistence(timeout: 20), "Expected the unified inbox row to be present on the sidebar root")
    }

    /// Bug 4 (above), unified-inbox variant: unified inbox → back → tap
    /// "すべての受信トレイ" again (the exact same row, same underlying
    /// value) → the message list must reappear, not stay stuck on the
    /// sidebar.
    func testRetappingTheSameSidebarRowAfterPoppingBackNavigatesAgain() throws {
        let app = XCUIApplication()
        app.launch()
        ensureDovecotTest1AccountExists(in: app)
        XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "Expected the message list to be reachable the first time")
        let list = app.collectionViews["messageList.list"]

        returnToSidebarRootIfNeeded(in: app)
        let sidebarList = app.collectionViews["sidebar.list"]
        XCTAssertTrue(sidebarList.waitForExistence(timeout: 20))

        let unifiedRow = sidebarList.cells.containing(NSPredicate(format: "label CONTAINS %@", "すべての受信トレイ")).firstMatch
        XCTAssertTrue(unifiedRow.waitForExistence(timeout: 10))
        unifiedRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        XCTAssertTrue(
            list.waitForExistence(timeout: 20),
            "Expected re-tapping \"すべての受信トレイ\" after popping back to navigate into the message list again, not stay stuck on the sidebar"
        )
        XCTAssertTrue(list.cells.firstMatch.waitForExistence(timeout: 20), "Expected the re-navigated message list to be populated, not empty")
    }

    /// Bug 4, thread variant: open a thread → back → tap the *same* row
    /// again → the detail pane must reopen, not stay stuck on the list.
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
