import XCTest

/// M4 verification, phase 2 (plan checkpoint (b): "スレッドを開くと 3 通、
/// 最新のみ展開"). Assumes `OtegamiM4SetupUITests` already ran in this
/// simulator install (account + seeded threads present in GRDB).
final class OtegamiM4ThreadDetailUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOpeningThreadShowsAllMessagesWithOnlyLatestExpanded() throws {
        let app = XCUIApplication()
        app.launch()

        let list = app.collectionViews["messageList.list"]
        let threadRow = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "来週のランチ")).firstMatch
        XCTAssertTrue(threadRow.waitForExistence(timeout: 30), "Expected the 3-message thread row to be present")
        threadRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        // Every message in the thread gets its own collapsed/expanded
        // header row, regardless of expansion state.
        let headers = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "threadDetail.message.") )
            .matching(NSPredicate(format: "identifier CONTAINS %@", ".header"))
        XCTAssertTrue(
            waitForCount(headers, atLeast: 3, timeout: 20),
            "Expected 3 message header rows in the thread detail view, found \(headers.count)"
        )

        // Only the newest message (seed-0011, "駅前のカフェはどうでしょう")
        // starts expanded — its body should be visible without tapping
        // anything.
        let latestBody = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "駅前のカフェ")).firstMatch
        XCTAssertTrue(latestBody.waitForExistence(timeout: 20), "Expected the newest message's body to be expanded by default")

        // Exactly one message's full `MessageView` (identified by its
        // `threadDetail.message.<id>.body` container) should be mounted at
        // a time — checking for *specific body text* being absent isn't
        // reliable here, since these seed messages are short enough that a
        // collapsed row's own snippet preview (`ThreadMessageSummaryRow`)
        // can already contain most/all of the same text the full body
        // would; counting mounted body containers sidesteps that.
        let bodies = app.descendants(matching: .any).matching(NSPredicate(format: "identifier CONTAINS %@", "threadDetail.message."))
            .matching(NSPredicate(format: "identifier CONTAINS %@", ".body"))
        XCTAssertEqual(bodies.count, 1, "Expected exactly one expanded message body before tapping any other header")

        // Tapping the oldest message's collapsed header expands it too
        // (plan: "ヘッダタップで展開") — now two bodies should be mounted.
        let oldestHeader = headers.element(boundBy: 0)
        XCTAssertTrue(oldestHeader.exists, "Expected at least one collapsed header row")
        oldestHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        XCTAssertTrue(
            waitForCount(bodies, atLeast: 2, timeout: 20),
            "Expected tapping the oldest header to expand a second message body, found \(bodies.count)"
        )
    }

    /// Polls `collection.count` until it reaches at least `minimum` or
    /// `timeout` elapses — `XCUIElementQuery.count` doesn't have a
    /// built-in "wait for N to exist" the way `waitForExistence` does for
    /// a single element.
    private func waitForCount(_ collection: XCUIElementQuery, atLeast minimum: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if collection.count >= minimum { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return collection.count >= minimum
    }
}
