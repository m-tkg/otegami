import XCTest

/// 「アーカイブしました」等のトースト (`UndoToast`) は、本体をタップすると
/// タイマー満了 (`MessageListView.undoWindow` = 5 秒) を待たずに即座に
/// 閉じる。「元に戻す」ボタン上のタップはこれまでどおり Undo のまま —
/// 本体のタップジェスチャが子のボタンを横取りしていないことも固定する。
///
/// 実接続には依存しない: DB 直接注入フィクスチャ + スワイプ
/// (`docs/verify.md` のとおり、このシミュレータでもスワイプは安定して届く)。
final class OtegamiUndoToastTapDismissUITests: XCTestCase {
    /// `MessageListView.undoWindow` (5 秒) より十分短い — これ以内に消えれば
    /// タイマー満了ではなくタップで閉じたと言える。
    private static let dismissDeadline: TimeInterval = 2

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE"] = "1"
        app.launchEnvironment["OTEGAMI_UITEST_DISABLE_AVATAR_SOURCES"] = "1"
        app.launchEnvironment["OTEGAMI_UITEST_DISABLE_NOTIFICATION_PERMISSION_REQUEST"] = "1"
        app.launchEnvironment["OTEGAMI_UITEST_DISABLE_CLOUD_SYNC"] = "1"
        return app
    }

    /// 行の identifier は `messageList.row.<threadId>` — 行の中の子要素
    /// (`...pinnedIndicator` 等) は suffix が付くので除外する。
    private func rowIdentifiers(in app: XCUIApplication) -> [String] {
        app.descendants(matching: .any).allElementsBoundByIndex
            .map { $0.identifier }
            .filter { $0.hasPrefix("messageList.row.") && $0.split(separator: ".").count == 3 }
    }

    /// 先頭行を trailing 方向へしきい値スワイプ (既定は削除) し、トーストが
    /// 出るところまで進める。消した行の identifier を返す。
    private func swipeAwayFirstRow(in app: XCUIApplication) throws -> String {
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20), "message list should be on screen")
        let identifier = try XCTUnwrap(rowIdentifiers(in: app).first, "fixture rows should be in the list")
        let row = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(performThresholdSwipe(on: row, distancePoints: -100, in: app))
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "swiped row should leave the list")
        return identifier
    }

    /// `undoToast` という identifier は、`UndoToast` の
    /// `.accessibilityElement(children: .combine)` の結果「元に戻す」ボタン
    /// 自身 (44pt 四方) に解決される — トーストのカプセル全体ではない。
    /// 存在確認と「ボタンを押す」にはそのまま使えるが、「本体を押す」には
    /// `tapToastBody(_:in:)` で画面座標を別に組み立てる必要がある。
    private func toast(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["undoToast"].firstMatch
    }

    /// トーストのメッセージ文言側 (画面左寄り、ボタンと同じ高さ) をタップ
    /// する — 右端の「元に戻す」ボタンには重ならない位置。
    private func tapToastBody(_ toast: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let point = CGVector(dx: window.width * 0.25, dy: toast.frame.midY)
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
    }

    func testTappingTheToastBodyDismissesItWithoutUndoing() throws {
        let app = makeApp()
        app.launch()

        let identifier = try swipeAwayFirstRow(in: app)
        let toast = toast(in: app)
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "undo toast should appear after the swipe")

        tapToastBody(toast, in: app)

        XCTAssertTrue(
            toast.waitForNonExistence(timeout: Self.dismissDeadline),
            "tapping the toast body must dismiss it right away, not after the undo window"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[identifier].firstMatch.exists,
            "dismissing is not an undo — the swiped row must stay gone"
        )
    }

    func testTappingTheUndoButtonStillUndoes() throws {
        let app = makeApp()
        app.launch()

        let identifier = try swipeAwayFirstRow(in: app)
        let toast = toast(in: app)
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "undo toast should appear after the swipe")

        // `toast(in:)` のコメントどおり、この要素は「元に戻す」ボタン自身。
        toast.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(
            app.descendants(matching: .any)[identifier].firstMatch.waitForExistence(timeout: 5),
            "the undo button must still restore the row — the body's tap gesture must not swallow it"
        )
    }
}
