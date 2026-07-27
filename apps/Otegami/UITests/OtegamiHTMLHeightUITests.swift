import XCTest

/// HTML表示の高さ問題 (実機フィードバック — WebView の表示エリアが画面の
/// 半分程度で頭打ちになり、本文が途中で切れ、その下に大きな空白が残る)の
/// 検証: `27-google-tos-style.eml` (`<head>` に MSO 条件付きコメント —
/// 中に "<body"/"</body>" という文字列を含むフォールバック骨格、Outlook
/// 向けテンプレートで一般的なパターン — と、本文がクラス経由でしか見た目
/// を制御していない `<style>` ブロックを両方含む、長文の Google 利用規約
/// 風メール) を開き、`HTMLDocumentBuilder.extractBodyContent(from:)`の
/// 修正前は先頭のコメント内フォールバック文言だけを本文として誤抽出し、
/// 実際の5セクションの本文がまるごと消えていた — この修正の検証は「本文の
/// *末尾*付近のテキスト (最後のセクション「5. 適用開始日」とフッターの
/// 著作権表記) がアクセシビリティツリーに現れるか」で行う。先頭付近の
/// テキストだけを確認しても (修正前のバグ品でも先頭の断片は何かしら
/// 表示されてしまう可能性があるため) 不十分 — `OtegamiM2VerificationUITests`
/// と同じ「WKWebView のテキストは label CONTAINS で横断検索する」方式
/// (`docs/verify.md`のメッセージ詳細画面の自動判定について参照)。
final class OtegamiHTMLHeightUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLongMarketingHTMLBodyIsNotTruncated() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        // `OtegamiWideMarketingHTMLUITests`と同じ理由 — フレッシュな
        // simulatorではこのアプリ初回起動時に通知許可ダイアログが出うる。
        allowNotificationPermissionIfNeeded(timeout: 10)

        let list = app.collectionViews["messageList.list"]
        if !list.waitForExistence(timeout: 5) {
            addDovecotTest1Account(in: app)
            allowNotificationPermissionIfNeeded(timeout: 10)
            restartAppToRecoverTouchDelivery(app)
        }
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        openMessage(subject: "利用規約の変更のお知らせ", in: app)

        // 本文冒頭近く (第1セクション) がまず表示されることを確認 —
        // ここまでは修正前のバグ品でも(コメント内フォールバック文言が)
        // 何か表示されてしまいうるので、単体では不十分な確認。
        assertBodyContains(text: "データの取り扱いについて", in: app)
        // 本文*末尾*近くのテキスト — 修正前は本文全体がコメント内の
        // フォールバック文言に置き換わり、実際の5セクションが丸ごと
        // 消えていたため、ここが現れることこそが修正の直接証拠になる。
        assertBodyContains(text: "適用開始日", in: app)
        assertBodyContains(text: "Google LLC", in: app)

        Thread.sleep(forTimeInterval: 2)

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "html-height-google-tos-message"
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
