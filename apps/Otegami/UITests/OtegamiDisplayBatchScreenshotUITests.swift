import XCTest

/// 表示・操作改善バッチの検証: カード状の一覧行/時刻表示 (1, 2)、スレッド詳細の
/// 折りたたみ行のアイコン/プレビュー (3)、本文画面のヘッダから件名が消えたこと
/// (4) を、実機さながらのスクリーンショットで目視確認するためのテスト。
/// `OtegamiDesignPhase3ScreenshotUITests`と同じ「テスト実行中に画面を保持し、
/// host 側の並行 `xcrun simctl io screenshot` が捉える」方式 — スレッド詳細も
/// アプリ再起動をまたいで復元されるとは限らないため、テスト終了後ではなく
/// 実行中に撮る必要がある (`docs/verify.md`のM6節参照)。
///
/// 作成画面の添付統合メニュー (7) はここに含めていない — `Menu`をタップして
/// 開いた状態そのものの自動検証を試みたところ、**この`Menu`固有ではなく**
/// このシミュレータ/ツールチェーン全体の問題であることを切り分け済み: 何も
/// 変更していない既存の `OtegamiTemplatesUITests`
/// (`composer.insertTemplateMenu`、design-phase-3から存在するテンプレート
/// 挿入メニュー) も同じ実行環境で同様に失敗することを確認した。`Menu`の
/// ポップオーバー表示自体か、その開いた状態を `xcodebuild test` 経由で
/// 検出する仕組みのどちらかが、このベータ版シミュレータ/Xcode で不安定に
/// なっている — アプリ側のコード (このバッチで触った `ComposerView`
/// `attachmentsMenu`、design-phase-3の`templateSection`のどちらも) が原因
/// ではないと判断した。添付メニューの「開いた状態」の目視確認は実機での
/// 確認に委ねる (最終報告のPENDING参照)。この自動テストでは「添付」ボタン
/// 自体が単一の統合ボタンとしてレンダリングされていること (閉じた状態) の
/// 構造確認までに留める。
final class OtegamiDisplayBatchScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHoldListAndThreadDetailForScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()
        addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)

        // Phase 1: 一覧 (カード状表示 + 時刻表示) — 直近のシード投入直後なので
        // 「今日」の時刻表示になる行が複数あるはず。
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 5)

        // Phase 2: スレッド詳細 (折りたたみ行のアイコン/プレビュー、ヘッダに
        // 件名を出さないこと) — 3通のスレッド「来週のランチ」を開く。
        let threadRow = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "来週のランチ")).firstMatch
        XCTAssertTrue(waitForElementScrollingIfNeeded(threadRow, in: app), "Expected the 3-message thread row to be present")
        threadRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        let detail = app.scrollViews["threadDetail.scrollView"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "Expected the thread detail pane to appear after tapping the thread row")
        let headers = detail.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "threadDetail.message."))
            .matching(NSPredicate(format: "identifier CONTAINS %@", ".header"))
        XCTAssertTrue(waitForCount(headers, atLeast: 3, timeout: 20), "Expected 3 message header rows, found \(headers.count)")
        Thread.sleep(forTimeInterval: 6)

        popBackOnceIfNeeded(in: app)

        // Phase 3: 作成画面の添付ボタン — 単一の統合ボタンとして存在すること
        // だけを確認する (メニューを開いた状態の検証は上記の doc comment
        // 参照)。
        let composeButton = app.buttons["mail.composeButton"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 15))
        composeButton.tap()
        let composerSheet = app.otherElements["composer.sheet"]
        XCTAssertTrue(composerSheet.waitForExistence(timeout: 15))
        app.swipeUp()
        let attachMenu = app.buttons["composer.attachMenu"]
        XCTAssertTrue(waitForElementScrollingIfNeeded(attachMenu, in: app), "Expected the unified attach menu button")
        Thread.sleep(forTimeInterval: 3)
    }

    /// See `OtegamiM4ThreadDetailUITests`'s identical private helper's doc
    /// comment — each UITest file that needs this keeps its own copy
    /// (established convention in this target, not shared).
    private func waitForCount(_ collection: XCUIElementQuery, atLeast minimum: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if collection.count >= minimum { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return collection.count >= minimum
    }
}
