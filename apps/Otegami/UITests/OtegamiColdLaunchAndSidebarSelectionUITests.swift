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
/// its first `ValueObservation` fetch could ever complete (a `Task`
/// `CancellationError` on an in-flight database read, captured via a
/// temporary debug counter mid-investigation) — a livelock that never
/// resolved on its own, not a one-time glitch. Fixed by converting
/// `SidebarView`'s selection-driving rows from `List(selection:)`/`.tag()`
/// to explicit `Button { selection = ... }` actions, the same pattern
/// `MessageListView`'s own rows already used for the identical reason.
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
        let emptyStateButton = app.buttons["sidebar.addAccountButton"]
        if emptyStateButton.waitForExistence(timeout: 5) {
            addDovecotTest1Account(in: app)
            restartAppToRecoverTouchDelivery(app)
        }
    }

    func testColdRelaunchAfterOpeningAThreadStartsFromTheListNotTheDetail() throws {
        let app = XCUIApplication()
        app.launch()

        let list = app.collectionViews["messageList.list"]
        ensureDovecotTest1AccountExists(in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 20), "Expected the message list to be reachable")

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
        // the list.
        app.terminate()
        app.launch()

        // Fixed behavior: a cold relaunch always starts from the list, not
        // the detail pane. (`messageList.list` itself always sits one push
        // level under the sidebar on compact width — M4's pitfall #3 in
        // `.claude/skills/verify/SKILL.md` — so a back button existing
        // isn't by itself a sign of anything wrong; what matters is that
        // `threadDetail.scrollView` is *not* also on screen, i.e. nothing
        // pushed a second level deeper than the list.)
        XCTAssertTrue(list.waitForExistence(timeout: 20), "Expected a cold relaunch to land on the message list, not a restored thread detail")
        XCTAssertFalse(
            app.scrollViews["threadDetail.scrollView"].exists,
            "Expected no restored thread detail pane on a cold relaunch — the app should come up on the list only"
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

    /// The reported "サイドバー → INBOX をタップすると一覧に何も出ない" symptom:
    /// pop back to the sidebar and tap a specific account's own INBOX
    /// mailbox row (not "すべての受信トレイ", which a cold launch already
    /// selects by default and so wouldn't actually exercise a mailbox
    /// *switch*) and confirm the list actually switches to (and populates
    /// from) that mailbox.
    func testTappingAMailboxRowInTheSidebarPopulatesItsMessageList() throws {
        let app = XCUIApplication()
        app.launch()

        let list = app.collectionViews["messageList.list"]
        ensureDovecotTest1AccountExists(in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 20), "Expected the message list to be reachable")

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
}
