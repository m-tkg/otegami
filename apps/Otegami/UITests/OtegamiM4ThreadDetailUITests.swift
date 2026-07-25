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
        // Scrolling (not just existence) matters here: `dev/mailstack/
        // seed/fixtures/` grew well past one screen's worth of rows since
        // this test was written (M10's doc note on
        // `waitForElementScrollingIfNeeded`'s other call sites) — this
        // thread now sorts below several newer M8 fixtures, so a bare
        // `waitForExistence` can find the (off-screen, not-yet-laid-out)
        // cell while a `.coordinate(...)` press on it still taps nothing.
        XCTAssertTrue(
            waitForElementScrollingIfNeeded(threadRow, in: app),
            "Expected the 3-message thread row to be present"
        )
        threadRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        // Scoped to the thread detail pane specifically, not `app` at
        // large: on this simulator/device size ("iPhone 17 Pro Max"),
        // `NavigationSplitView` renders content and detail side by side
        // rather than collapsing to compact width, so `messageList.list`'s
        // own row for this same thread (also showing "来週のランチ" in its
        // subject) stays on screen right next to the detail pane —
        // querying `app.staticTexts` unscoped double-counts it.
        let detail = app.scrollViews["threadDetail.scrollView"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "Expected the thread detail pane to appear after tapping the thread row")

        // Every message in the thread gets its own collapsed/expanded
        // header row, regardless of expansion state.
        let headers = detail.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "threadDetail.message."))
            .matching(NSPredicate(format: "identifier CONTAINS %@", ".header"))
        XCTAssertTrue(
            waitForCount(headers, atLeast: 3, timeout: 20),
            "Expected 3 message header rows in the thread detail view, found \(headers.count)"
        )

        // Only the newest message (seed-0011, "駅前のカフェはどうでしょう")
        // starts expanded — its body should be visible without tapping
        // anything.
        let latestBody = detail.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "駅前のカフェ")).firstMatch
        XCTAssertTrue(latestBody.waitForExistence(timeout: 20), "Expected the newest message's body to be expanded by default")

        // Exactly one `MessageView` should be mounted at a time — counted
        // by its subject header text ("来週のランチ", shared by all 3
        // messages' subjects: the original and both "Re:" replies), which
        // only ever appears inside an *expanded* `MessageView`
        // (`ThreadMessageSummaryRow`, the collapsed header, never renders
        // the subject — only sender/snippet/date), never any collapsed
        // header row. Neither an identifier-based query
        // (`messageDetail.subject`, exact *or* `CONTAINS` — this
        // simulator/toolchain's accessibility bridging didn't expose it to
        // either form) nor a container-level `...body` identifier query
        // (over-counted to 5 for one mounted instance — nested elements
        // apparently inherit/re-report an ancestor's identifier here) held
        // up; a label-text `CONTAINS` search restricted to text that only
        // exists in the expanded state, scoped to `detail` (see above),
        // does.
        let subjects = detail.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "来週のランチ"))
        XCTAssertEqual(subjects.count, 1, "Expected exactly one expanded message body before tapping any other header")

        // Tapping the oldest message's collapsed header expands it too
        // (plan: "ヘッダタップで展開") — now two bodies should be mounted.
        let oldestHeader = headers.element(boundBy: 0)
        XCTAssertTrue(oldestHeader.exists, "Expected at least one collapsed header row")
        oldestHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        XCTAssertTrue(
            waitForCount(subjects, atLeast: 2, timeout: 20),
            "Expected tapping the oldest header to expand a second message body, found \(subjects.count)"
        )

        // Hold the thread open for the wrapping shell script's mid-test
        // screenshot (same technique as M6/M8) — `RootView`'s "last opened
        // thread" restoration is same-session-only now, not cross-launch
        // (`OtegamiApp.swift`'s `hasSkippedInitialRestoration` doc
        // comment), so `scripts/verify-ios-m4.sh` can no longer screenshot
        // this thread by relaunching after the test process exits.
        Thread.sleep(forTimeInterval: 4)
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
