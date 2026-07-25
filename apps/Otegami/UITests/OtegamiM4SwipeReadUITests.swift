import XCTest

/// M4 verification, phase 3 (plan checkpoint (d): "スレッド一括既読スワイプ →
/// doveadm で両メッセージに \Seen"). Swipes the 02/03 two-message
/// References-linked thread ("明日の打ち合わせについて" / "Re: 明日の打ち合わせに
/// ついて") to "既読にする" — `scripts/verify-ios-m4.sh` then confirms via
/// `doveadm fetch` from the host that *both* underlying messages picked up
/// `\Seen` server-side, not just the one whose subject the row happens to
/// display.
final class OtegamiM4SwipeReadUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSwipeMarksWholeThreadRead() throws {
        let app = XCUIApplication()
        app.launch()

        // No `popBackOnceIfNeeded` here — `RootView`'s "last opened
        // thread" restoration is same-session-only now (docs/verify.md),
        // so a fresh launch with an existing account always starts
        // *already on* the message list (one push level under the
        // sidebar, not two). Popping here would overshoot past the list
        // to the sidebar instead.
        let list = app.collectionViews["messageList.list"]
        func subjectRow() -> XCUIElement {
            list.cells.containing(NSPredicate(format: "label CONTAINS %@", "Re: 明日の打ち合わせについて")).firstMatch
        }
        // Scrolling (not just existence) matters here: `dev/mailstack/
        // seed/fixtures/` grew well past one screen's worth of rows since
        // this test was written — see `OtegamiM4ThreadDetailUITests`'s
        // matching fix for the same reason.
        XCTAssertTrue(
            waitForElementScrollingIfNeeded(subjectRow(), in: app),
            "Expected the 2-message thread row to be present"
        )

        // One more scroll step past "exists" — `waitForElementScrollingIfNeeded`
        // stops the instant the row becomes findable, which (scrolling
        // *down* through a newest-first list to reveal an older row) can
        // land it right at the bottom edge of the viewport. A swipe that
        // close to the edge doesn't reliably reveal the action — the exact
        // gotcha `OtegamiM3SwipeActionsUITests.testSwipeDeletesMessageOffline`
        // already documents for the same drag helper — so nudge it clear
        // before swiping. Re-queried after scrolling since a scroll can
        // invalidate the previous element reference.
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        start.press(forDuration: 0.05, thenDragTo: end)
        let row = subjectRow()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Expected the 2-message thread row to still be present after nudging it clear of the edge")

        // Leading swipe reveals the toggle-read action
        // (`.swipeActions(edge: .leading)` in `MessageListView`).
        row.swipeRight()

        let toggleReadButton = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "toggleRead")).firstMatch
        XCTAssertTrue(toggleReadButton.waitForExistence(timeout: 10), "Expected the leading swipe action button to appear")
        toggleReadButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        XCTAssertTrue(toggleReadButton.waitForNonExistence(timeout: 10), "Swipe action should dismiss once tapped")
    }
}
