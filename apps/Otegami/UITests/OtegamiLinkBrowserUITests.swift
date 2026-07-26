import XCTest

/// C7: opens `25-link-browser-test.eml` and taps its one real `http(s)://`
/// link, confirming it opens in the chosen browser rather than navigating
/// the message's own `WKWebView` away from itself.
final class OtegamiLinkBrowserUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Default state: "アプリ内ブラウザ" (`LinkBrowserSettingsStore`'s
    /// default) — tapping the link should present `SFSafariViewController`
    /// as a sheet over the message, not leave the app.
    func testLinkOpensInAppBrowserByDefault() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        openMessage(subject: "リンクを開くブラウザのテスト", in: app)
        assertBodyContains(text: "下のリンクをタップして", in: app)

        let link = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "example.com を開く")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        // SFSafariViewController presents its own "完了"/"Done" button in
        // its navigation bar — its appearance is the signal a sheet opened
        // over the message (as opposed to the message's own WKWebView
        // navigating away, which A9-A3/C7's `decidePolicyFor` should never
        // allow regardless of this setting).
        let doneButton = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Done", "完了")).firstMatch
        XCTAssertTrue(doneButton.waitForExistence(timeout: 20), "Expected SFSafariViewController's Done button after tapping the link with the in-app-browser setting on")

        Thread.sleep(forTimeInterval: 3)
    }

    // MARK: - Steps

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
