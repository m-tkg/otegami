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

        let list = app.collectionViews["messageList.list"]
        let row = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "Re: 明日の打ち合わせについて")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Expected the 2-message thread row to be present")

        // Leading swipe reveals the toggle-read action
        // (`.swipeActions(edge: .leading)` in `MessageListView`).
        row.swipeRight()

        let toggleReadButton = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "toggleRead")).firstMatch
        XCTAssertTrue(toggleReadButton.waitForExistence(timeout: 10), "Expected the leading swipe action button to appear")
        toggleReadButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        XCTAssertTrue(toggleReadButton.waitForNonExistence(timeout: 10), "Swipe action should dismiss once tapped")
    }
}
