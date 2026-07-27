import XCTest

/// M4 verification, phase 2 (plan checkpoint (b): "スレッドを開くと 3 通、
/// 最新のみ展開") — **rewritten for 画面構造改修バッチ (Task #33, 1)**, which
/// deliberately replaced the behavior this suite originally checked. The
/// user's own report ("メール本文のエリアが狭い。スレッド表示にする場合、
/// スレッドを選ぶ画面を別で挟んで、メール本文の画面ではスレッドは出さない
/// 方がいい") is the exact opposite of "開くと全メッセージがアコーディオンで
/// 並ぶ" this file used to assert — a 2+ message thread now interposes
/// `ThreadSelectionView` (`ThreadEntryView`'s doc comment) before
/// `ThreadDetailView`, and `ThreadDetailView` itself never shows more than
/// one message once reached this way (`singleMessageId`, not the full
/// accordion). Each test below is self-contained (adds the account itself
/// if genuinely starting from zero, `OtegamiQASweepUITests`'s
/// `ensureDovecotTest1AccountExists(in:)` pattern) rather than assuming a
/// separate setup phase already ran in this simulator install — this file
/// used to assume `OtegamiM4SetupUITests` ran first, which only holds when
/// the *entire* UITest target runs in file-declaration order; verifying
/// just this file in isolation (e.g. `-only-testing:OtegamiUITests
/// /OtegamiM4ThreadDetailUITests`) needs it to stand on its own.
final class OtegamiM4ThreadDetailUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// See `OtegamiQASweepUITests.ensureDovecotTest1AccountExists(in:)`'s
    /// identical doc comment — same reasoning, kept as this file's own
    /// copy per this UITest target's established "each file keeps its own
    /// small helpers" convention.
    private func ensureDovecotTest1AccountExists(in app: XCUIApplication) {
        let emptyStateButton = app.buttons["mail.addAccountButton"]
        if emptyStateButton.waitForExistence(timeout: 5) {
            addDovecotTest1Account(in: app)
            restartAppToRecoverTouchDelivery(app)
        }
    }

    /// The 3-message thread this suite has always used ("来週のランチ" /
    /// "Re: 来週のランチ" ×2, newest body "駅前のカフェはどうでしょう") now
    /// lands on the selection screen first, not the accordion detail view.
    func testOpeningAMultiMessageThreadShowsSelectionScreenThenSingleMessage() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()
        ensureDovecotTest1AccountExists(in: app)

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

        // 画面構造改修バッチ (Task #33, 1): a thread with 2+ messages now
        // opens `ThreadSelectionView` first — one row per message, same
        // information a list row already shows (icon/preview/time).
        let selection = app.scrollViews["threadSelection.scrollView"]
        XCTAssertTrue(selection.waitForExistence(timeout: 20), "Expected the thread selection screen to appear for a 3-message thread")

        let selectionRows = selection.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "threadSelection.message."))
        XCTAssertTrue(
            waitForCount(selectionRows, atLeast: 3, timeout: 20),
            "Expected 3 rows on the thread selection screen, found \(selectionRows.count)"
        )

        // Tapping the newest row (last in the list, oldest-first per
        // `ThreadSelectionView`'s doc comment) pushes straight to that one
        // message's body — no selection UI carries over onto that screen.
        let newestRow = selectionRows.element(boundBy: selectionRows.count - 1)
        newestRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        let detail = app.scrollViews["threadDetail.scrollView"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "Expected the message body screen to appear after tapping a selection row")

        // 「本文画面ではスレッドのアコーディオン/スタックを出さない」— exactly
        // one message header mounted, never the old 3-row accordion this
        // test used to assert.
        let headers = detail.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "threadDetail.message."))
            .matching(NSPredicate(format: "identifier CONTAINS %@", ".header"))
        XCTAssertTrue(waitForCount(headers, atLeast: 1, timeout: 20), "Expected the single-message body screen to mount its one header row")
        XCTAssertEqual(headers.count, 1, "Expected no thread accordion/stack on the message body screen, found \(headers.count) header rows")

        let latestBody = detail.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "駅前のカフェ")).firstMatch
        XCTAssertTrue(latestBody.waitForExistence(timeout: 20), "Expected the tapped (newest) message's body to be shown")

        // Hold the message open for the wrapping shell script's mid-test
        // screenshot (same technique as M6/M8).
        Thread.sleep(forTimeInterval: 4)
    }

    /// A single-message thread ("ようこそ otegami へ", seed-0001) skips the
    /// selection screen entirely and opens straight into the body — the
    /// other half of 画面構造改修バッチ (Task #33, 1)'s approved behavior
    /// ("スレッドが1通だけなら選択画面をスキップして直接本文へ").
    func testOpeningASingleMessageThreadSkipsTheSelectionScreen() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()
        ensureDovecotTest1AccountExists(in: app)

        let list = app.collectionViews["messageList.list"]
        let subject = "ようこそotegamiへ"
        XCTAssertTrue(waitForSeededSubjectScrollingIfNeeded(subject, in: app), "Expected the single-message welcome seed to appear")
        let threadRow = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "ようこそ")).firstMatch
        threadRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        let detail = app.scrollViews["threadDetail.scrollView"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "Expected a 1-message thread to open straight into the body screen")
        XCTAssertFalse(
            app.scrollViews["threadSelection.scrollView"].exists,
            "Expected the selection screen to be skipped entirely for a 1-message thread"
        )

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
