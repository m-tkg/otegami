import XCTest

/// M4 verification, phase 2 (plan checkpoint (b): "スレッドを開くと 3 通、
/// 最新のみ展開") — **rewritten again for Task #136** (実機フィードバック
/// 「スレッド表示 ON の本文画面をアコーディオンに戻してほしい」), which
/// reverted 画面構造改修バッチ (Task #33, 1)'s intermediate
/// `ThreadSelectionView` step this file was rewritten to check at the time.
/// A 2+ message thread once again opens straight into `ThreadDetailView`'s
/// accordion — every message in the thread laid out vertically, newest
/// expanded, the rest collapsed to a one-line summary — exactly what this
/// file originally asserted before Task #33. Each test below is
/// self-contained (adds the account itself if genuinely starting from zero,
/// `OtegamiQASweepUITests`'s `ensureDovecotTest1AccountExists(in:)` pattern)
/// rather than assuming a separate setup phase already ran in this
/// simulator install — this file used to assume `OtegamiM4SetupUITests` ran
/// first, which only holds when the *entire* UITest target runs in
/// file-declaration order; verifying just this file in isolation (e.g.
/// `-only-testing:OtegamiUITests/OtegamiM4ThreadDetailUITests`) needs it to
/// stand on its own.
final class OtegamiM4ThreadDetailUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// See `OtegamiQASweepUITests.ensureDovecotTest1AccountExists(in:)`'s
    /// identical doc comment — same reasoning, kept as this file's own
    /// copy per this UITest target's established "each file keeps its own
    /// small helpers" convention.
    private func ensureDovecotTest1AccountExists(in app: XCUIApplication) throws {
        let emptyStateButton = app.buttons["mail.addAccountButton"]
        if emptyStateButton.waitForExistence(timeout: 5) {
            try addDovecotTest1Account(in: app)
            restartAppToRecoverTouchDelivery(app)
        }
    }

    /// The 3-message thread this suite has always used ("来週のランチ" /
    /// "Re: 来週のランチ" ×2, newest body "駅前のカフェはどうでしょう") opens
    /// directly into the accordion — one header row per message, the newest
    /// expanded, the other two collapsed to their one-line summary.
    func testOpeningAMultiMessageThreadShowsAccordionWithAllMessages() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()
        try ensureDovecotTest1AccountExists(in: app)

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

        let detail = app.scrollViews["threadDetail.scrollView"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "Expected the thread to open straight into the accordion body screen")

        // Task #136: every message in the thread gets its own header row —
        // no intermediate selection screen, no single-message-only body.
        let headers = detail.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "threadDetail.message."))
            .matching(NSPredicate(format: "identifier CONTAINS %@", ".header"))
        XCTAssertTrue(waitForCount(headers, atLeast: 3, timeout: 20), "Expected 3 header rows in the accordion, found \(headers.count)")
        XCTAssertEqual(headers.count, 3, "Expected exactly 3 header rows, found \(headers.count)")

        // The newest message ("駅前のカフェ…") is pinned expanded on first
        // load — its body should already be visible without any tap.
        let latestBody = detail.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "駅前のカフェ")).firstMatch
        XCTAssertTrue(latestBody.waitForExistence(timeout: 20), "Expected the newest message's body to be shown expanded by default")

        // Tapping the oldest (first) header collapses the newest and
        // expands the oldest instead — a strict accordion, exactly one
        // message expanded at a time.
        let oldestHeader = headers.element(boundBy: 0)
        oldestHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        let oldestBody = detail.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "threadDetail.message."))
            .matching(NSPredicate(format: "identifier CONTAINS %@", ".body"))
        XCTAssertTrue(waitForCount(oldestBody, atLeast: 1, timeout: 20), "Expected tapping the oldest header to expand its body")
        XCTAssertEqual(oldestBody.count, 1, "Expected exactly one expanded body at a time (strict accordion), found \(oldestBody.count)")

        // Hold the message open for the wrapping shell script's mid-test
        // screenshot (same technique as M6/M8).
        Thread.sleep(forTimeInterval: 4)
    }

    /// A single-message thread ("ようこそ otegami へ", seed-0001) still opens
    /// straight into the body, rendering as "one row, always expanded" — the
    /// same accordion view degenerating naturally to a single message, per
    /// its own doc comment.
    func testOpeningASingleMessageThreadShowsOneExpandedRow() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()
        try ensureDovecotTest1AccountExists(in: app)

        let list = app.collectionViews["messageList.list"]
        let subject = "ようこそotegamiへ"
        XCTAssertTrue(waitForSeededSubjectScrollingIfNeeded(subject, in: app), "Expected the single-message welcome seed to appear")
        let threadRow = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "ようこそ")).firstMatch
        threadRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        let detail = app.scrollViews["threadDetail.scrollView"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "Expected a 1-message thread to open straight into the body screen")

        let headers = detail.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "threadDetail.message."))
            .matching(NSPredicate(format: "identifier CONTAINS %@", ".header"))
        XCTAssertTrue(waitForCount(headers, atLeast: 1, timeout: 20), "Expected the single message's header row to mount")
        XCTAssertEqual(headers.count, 1, "Expected exactly one header row for a 1-message thread")
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
