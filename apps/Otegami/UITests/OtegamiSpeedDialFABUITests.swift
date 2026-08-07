import XCTest

/// 実機報告 (2026-08-07)「iOS アプリで、右下の … ボタンを押しても何も
/// 出なくなっている」の再発防止。Liquid Glass Phase 1 で FAB の円塗りを
/// 廃止した結果、`.buttonStyle(.plain)` のヒットテストが「…」の点3つの
/// 形にまで縮み、円の余白をタップしても展開しなくなっていた
/// (`MailScreenView.SpeedDialFAB.fabToggleButton` の `contentShape` の
/// コメント参照)。
///
/// このテストは**円の中心ではなく、アイコンの描画から外れた円の縁**を
/// 突く — 中心 (点そのもの) はバグのある実装でも当たってしまい、回帰を
/// 検出できないため。`docs/verify.md` の既知不調 (一覧行タップが届かない)
/// とは別物で、こちらは常に同じ座標にある単独のフローティングボタン。
final class OtegamiSpeedDialFABUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFABTogglesFromTheCircleEdgeNotJustTheGlyph() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_DISABLE_AVATAR_SOURCES"] = "1"
        app.launchEnvironment["OTEGAMI_UITEST_DISABLE_NOTIFICATION_PERMISSION_REQUEST"] = "1"
        app.launchEnvironment["OTEGAMI_UITEST_DISABLE_CLOUD_SYNC"] = "1"
        app.launch()

        let toggle = app.buttons["mail.fabToggleButton"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "speed-dial FAB should exist on the message list")

        // 円の左上寄り (0.2, 0.2) — グリフ (中央の点3つ) には重ならないが、
        // ガラスの円の内側には収まる位置。
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()

        let searchButton = app.buttons["mail.searchButton"]
        XCTAssertTrue(
            searchButton.waitForExistence(timeout: 5),
            "tapping the FAB's circle (off-glyph) must expand the speed dial"
        )

        // 畳む側も同じ座標で効くこと (展開中は "×" になり、グリフの形が
        // 変わってもヒット領域は円のまま)。
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        XCTAssertTrue(
            searchButton.waitForNonExistence(timeout: 5),
            "tapping it again must collapse the speed dial"
        )
    }
}
