import XCTest

/// 実機フィードバック検証 (「htmlメールの場合、レイアウトをなるべく崩さない
/// ように翻訳を表示して欲しい」): HTML メールの翻訳が `TranslatedBodyView`
/// (プレーンテキストへの総入れ替え、レイアウト全損) ではなく
/// `HTMLTranslationController`によるDOMテキストノード書き換えで行われ、
/// 表・画像・罫線などのレイアウトを保ったまま文字だけが日本語化される
/// ことを確認する。
///
/// `OTEGAMI_UITEST_FAKE_TRANSLATION=1`: このプロジェクトの Simulator/ホスト
/// 環境では sandboxed `.app` プロセスから Foundation Models を実際には
/// 呼べない (`AppEnvironment.swift`の同フラグの doc comment 参照) ため、
/// `FakeTranslationService`(決定的な`"[ja] ..."`出力) に差し替えて DOM 書き
/// 換え経路そのものを検証する — `docs/translation.md`の「既知の制限」に
/// 記載の通り、実機/実 Simulator での Foundation Models 自体の可否とは
/// 独立に、この経路のコードが正しく動くことは確認できる。
final class OtegamiHTMLTranslationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHTMLTranslationPreservesLayoutAndTranslatesText() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_FAKE_TRANSLATION"] = "1"
        app.launch()

        allowNotificationPermissionIfNeeded(timeout: 10)

        let list = app.collectionViews["messageList.list"]
        if !list.waitForExistence(timeout: 5) {
            try addDovecotTest1Account(in: app)
            allowNotificationPermissionIfNeeded(timeout: 10)
            restartAppToRecoverTouchDelivery(app)
        }
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        openMessage(subject: "Your payment has been processed", in: app)

        // 実機フィードバック「翻訳機能は、勝手に実行しないで欲しい」: 自動
        // 翻訳は既定オフなので、まず原文 (英語) のまま表示されていること
        // を確認してから、明示的に「翻訳」を押す。
        assertBodyContains(text: "Dear Taro Yamada", in: app)

        let translateButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "翻訳")).firstMatch
        XCTAssertTrue(translateButton.waitForExistence(timeout: 20), "Expected the idle 翻訳 button (auto-translate defaults to off)")
        translateButton.tap()

        // `FakeTranslationService.deterministicTranslation`は`"[ja] <text>"`
        // を返す — このマーカーが本文中に現れることが、DOM テキスト
        // ノードが実際に書き換わったことの証拠 (レイアウトはこの検証だけ
        // からは断定できないため、下のスクリーンショットで目視確認する)。
        let translatedMarker = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "[ja]")).firstMatch
        XCTAssertTrue(translatedMarker.waitForExistence(timeout: 20), "Expected translated ([ja] ...) text to appear in the HTML body")

        // 訳文/原文セグメントで「原文」に戻すと、書き換え前の英語が
        // 復元されることも確認する — レイアウト保持翻訳の「原文を表示」
        // 切替が機能している証拠。
        let originalSegment = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "原文")).firstMatch
        if originalSegment.waitForExistence(timeout: 10) {
            originalSegment.tap()
            assertBodyContains(text: "Dear Taro Yamada", in: app)
        }

        Thread.sleep(forTimeInterval: 2)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "html-translation-layout-preserved"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Task #128 (実機報告「英語メールなのに翻訳ボタンが押せない」— Okta の
    /// サインオン通知メール, hypothesis (2)): reproduces the *stale wrong
    /// `detectedLanguage`* scenario with an anonymized fixture
    /// (`AppEnvironment.uitestFakeHTMLMessageBodySSONotice`, index 8 of
    /// `uitestFakeHTMLMessages`, seeded with `detectedLanguage: "fr"` —
    /// standing in for an old build's incorrect detection, not an actually
    /// French message) rather than the real (uncommittable) `.eml`.
    /// `MessageView.load()`'s `backfillDetectedLanguageIfNeeded` (relaxed by
    /// this task to re-detect and correct a *disagreeing* non-`nil` value,
    /// not just a missing one) should re-detect English from this fixture's
    /// genuinely-English body and overwrite the wrong stored value — so the
    /// 翻訳 bar/button should end up visible and tappable despite the bad
    /// starting state, exactly the behavior a real user hitting this bug
    /// would need to see fixed. Uses the same `OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX`
    /// tap-free direct-open path `OtegamiSecurityNoticeDarkModeUITests`
    /// already established (Task #56) for the same "row tap unreliable on
    /// this simulator/toolchain" reason.
    func testEnglishMessageWithStaleWrongDetectedLanguageStillShowsTranslateButton() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE"] = "1"
        app.launchEnvironment["OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX"] = "8"
        app.launch()

        for _ in 0..<4 {
            allowNotificationPermissionIfNeeded(timeout: 2)
            dismissContactsPermissionPromptIfNeeded(timeout: 2)
        }

        XCTAssertTrue(waitForMessageDetailToAppear(in: app, timeout: 20), "Expected the direct-open path to land on the message detail view (htmlWebView never appeared)")
        assertBodyContains(text: "New sign-in to Example App", in: app)

        // The actual bug this test locks in: despite the fixture's stored
        // `detectedLanguage` starting out wrong ("fr"), the translate button
        // must still appear once the body's finished loading and the
        // re-detection in `load()` has run.
        let translateButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "翻訳")).firstMatch
        XCTAssertTrue(translateButton.waitForExistence(timeout: 20), "Expected the 翻訳 button to appear despite a stale, wrong stored detectedLanguage")

        screenshotCurrentScreen(named: "translate-button-visible-despite-stale-detected-language", in: app)
    }

    private func waitForMessageDetailToAppear(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let webView = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier CONTAINS %@", "messageDetail.htmlWebView")
        ).firstMatch
        return webView.waitForExistence(timeout: timeout)
    }

    private func screenshotCurrentScreen(named name: String, in app: XCUIApplication) {
        Thread.sleep(forTimeInterval: 2)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
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
