import XCTest

/// M3 verification, phases 3/4 ("フラグ同期" / "オフライン操作キュー"): swipe
/// actions on `MessageListView` rows. Both test methods assume the account
/// from `OtegamiM3SetupUITests` is already persisted (Keychain + GRDB
/// survive a relaunch); `scripts/verify-ios-m3.sh` runs
/// `testSwipeMarksMessageRead` while the mailstack is up (so the opQueue's
/// best-effort immediate replay actually reaches the server — verified via
/// `doveadm fetch` from the host afterward) and `testSwipeDeletesMessageOffline`
/// while it's stopped (so only the local optimistic removal + enqueue can
/// be confirmed here; the replay-once-back-online part is verified by the
/// script after `make mailstack-up`, again via `doveadm`).
final class OtegamiM3SwipeActionsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSwipeMarksMessageRead() throws {
        let app = XCUIApplication()
        app.launch()

        let subject = "明日の打ち合わせについて"
        let row = row(forSubject: subject, in: app)

        // Leading swipe (left-to-right drag) reveals the "既読にする" /
        // "未読にする" action (`.swipeActions(edge: .leading)` in
        // `MessageListView`).
        swipe(row, from: 0.05, to: 0.9)

        let markReadButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "既読にする")).firstMatch
        XCTAssertTrue(markReadButton.waitForExistence(timeout: 10), "Expected the leading swipe action to reveal \"既読にする\"")
        markReadButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        XCTAssertTrue(markReadButton.waitForNonExistence(timeout: 10), "Swipe action should dismiss once tapped")
    }

    func testSwipeDeletesMessageOffline() throws {
        let app = XCUIApplication()
        app.launch()

        let subject = "M3差分同期テスト"
        let row = row(forSubject: subject, in: app)

        // Trailing swipe (right-to-left drag) reveals "削除"
        // (`.swipeActions(edge: .trailing)` in `MessageListView`).
        swipe(row, from: 0.9, to: 0.05)

        let deleteButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "削除")).firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 10), "Expected the trailing swipe action to reveal \"削除\"")
        deleteButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        XCTAssertTrue(
            row.waitForNonExistence(timeout: 10),
            "Expected the deleted message to disappear from the list immediately (local optimistic removal, opQueue delete enqueued for replay once back online)"
        )
    }

    // MARK: - Steps

    private func row(forSubject subject: String, in app: XCUIApplication) -> XCUIElement {
        let list = app.collectionViews["messageList.list"]
        let row = list.cells.containing(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Expected message \"\(subject)\" to be in the list")
        return row
    }

    /// A direct coordinate press-and-drag (rather than `XCUIElement`'s
    /// `.swipeLeft()`/`.swipeRight()` convenience methods) for the same
    /// reason `openMessage`'s row tap in `OtegamiM2VerificationUITests`
    /// uses an explicit coordinate rather than plain `.tap()` — see
    /// `.claude/skills/verify/SKILL.md`'s "M2: this simulator/toolchain's
    /// touch-delivery bugs" section. Not confirmed to be strictly necessary
    /// for a swipe specifically (only tap's "scroll-to-visible" step was
    /// diagnosed as broken there), but consistent with the rest of this
    /// suite's established workaround.
    private func swipe(_ element: XCUIElement, from startEdge: CGFloat, to endEdge: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: startEdge, dy: 0.5))
        let end = element.coordinate(withNormalizedOffset: CGVector(dx: endEdge, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
}
