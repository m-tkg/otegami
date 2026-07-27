import XCTest

/// 実機フィードバック検証: 楽天銀行のような幅600-800px級の固定幅テーブル
/// HTMLメールが、以前は等倍描画され右端がクリップ・文字が巨大に見えて
/// いた不具合の fit-to-width 修正 (`HTMLDocumentBuilder.wrap(bodyHTML:)`/
/// `HTMLWebViewCoordinator.fitToWidthScript`) を、`29-fixed-width-bank-
/// notice.eml` (幅700pxの中央寄せテーブル + `white-space: nowrap` の
/// ラベル/値行 + 改行なしの区切り線 — 実物に近い構造) を開いてスクリーン
/// ショットで確認する。`OtegamiWideMarketingHTMLUITests`/
/// `OtegamiHTMLHeightUITests`と同じ「合否の実質的なシグナルは目視 (このテスト
/// 自身はアサートしない)」パターン — WKWebView の描画そのもの (右端が
/// 切れていないか、フォントの実寸) はアクセシビリティツリーから判定でき
/// ないため。テキスト自体がアクセシビリティツリーに現れることだけは
/// 確認する (fit-to-width が本文を消してしまっていないことの最低限の証拠)。
final class OtegamiFitToWidthUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFixedWidthBankNoticeRendersFullyOnScreen() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        allowNotificationPermissionIfNeeded(timeout: 10)

        let list = app.collectionViews["messageList.list"]
        if !list.waitForExistence(timeout: 5) {
            addDovecotTest1Account(in: app)
            allowNotificationPermissionIfNeeded(timeout: 10)
            restartAppToRecoverTouchDelivery(app)
        }
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        openMessage(subject: "お支払いのお知らせ", in: app)
        // 冒頭 (見出し直後の宛名) と、修正前は途中で本文が切れて到達しな
        // かった末尾付近 (フッターのURL手前のテキスト) の両方を確認 —
        // `OtegamiHTMLHeightUITests`と同じ「先頭だけでは不十分」という
        // 教訓を踏襲。
        assertBodyContains(text: "太郎様", in: app)
        assertBodyContains(text: "お問い合わせください", in: app)
        // WKWebView がレイアウト/ペイントを終える猶予 — 他の HTML 系
        // UITest と同じ理由 (`assertBodyContains`はアクセシビリティ
        // ツリーにテキストノードが存在することしか確認せず、視覚的に
        // 収まっているかは別)。
        Thread.sleep(forTimeInterval: 2)

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "fit-to-width-bank-notice"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openMessage(subject: String, in app: XCUIApplication) {
        let list = app.collectionViews["messageList.list"]
        let predicate = NSPredicate(format: "label CONTAINS %@", subject)
        let row = list.cells.containing(predicate).firstMatch
        XCTAssertTrue(waitForElementScrollingIfNeeded(row, in: app), "Expected seeded message \"\(subject)\" to appear in the INBOX list")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
    }

    private func assertBodyContains(text: String, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let element = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "Expected message body to contain \"\(text)\"")
    }
}
