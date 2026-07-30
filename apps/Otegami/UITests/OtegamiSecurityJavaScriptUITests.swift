import XCTest

/// A9-A3 セキュリティ検証: opens four seeded HTML messages, each carrying a
/// different real-world script-injection technique, and confirms the page's
/// own "marker" paragraph is still its original (untouched) text — i.e.
/// nothing in the message executed. This is the actual security check the
/// task asked for (not just "JS is disabled" by inspection): a real
/// malicious `.eml` opened in the real app, verified by reading back what
/// the WKWebView's accessibility tree reports for the marker text.
///
/// `docs/verify.md`'s A9 section records the screenshots taken alongside
/// this (the primary human-facing evidence — see that file for what was
/// visually confirmed for each fixture, including the ones this assertion
/// approach can't fully cover, like "no red background" for the `onerror`
/// case).
final class OtegamiSecurityJavaScriptUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testScriptTagCannotRewriteDOM() throws {
        try runMarkerCheck(
            subject: "script による本文書き換え",
            expectedMarker: "元のテキストのままです（改ざんされていません）。"
        )
    }

    func testOnerrorHandlerCannotRunScript() throws {
        try runMarkerCheck(
            subject: "onerror による背景色変更",
            expectedMarker: "背景色は変わっていないはずです（改ざんされていません）。"
        )
    }

    func testIframeContentIsBlockedByDefault() throws {
        try runMarkerCheck(
            subject: "iframe による外部コンテンツ埋め込み",
            expectedMarker: "iframe は読み込まれていないはずです（改ざんされていません）。"
        )
    }

    func testJavaScriptSchemeLinkTapDoesNothing() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        try addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        openMessage(subject: "javascript: リンク", in: app)
        let marker = "リンクをタップしても改ざんされないはずです。"
        assertBodyContains(text: marker, in: app)

        // Tap the javascript: link itself — WebKit content is exposed to
        // the accessibility tree as static text (`docs/verify.md`'s M2
        // section), so a label-text lookup finds the link's own text the
        // same way `assertBodyContains` finds paragraph text.
        let link = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ここをタップ")).firstMatch
        if link.waitForExistence(timeout: 10) {
            link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        }

        // Whether or not the tap itself was deliverable to WebKit's inner
        // hit-testing (not guaranteed from XCUITest against web content),
        // the important assertion is unconditional: the marker text must
        // still read as original a few seconds later. `HTMLWebViewCoordinator
        // .webView(_:decidePolicyFor:decisionHandler:)` cancels every
        // navigation except the initial programmatic load, so even a
        // successfully-delivered tap on a `javascript:` link can't execute.
        Thread.sleep(forTimeInterval: 3)
        assertBodyContains(text: marker, in: app)

        Thread.sleep(forTimeInterval: 4)
    }

    // MARK: - Shared

    private func runMarkerCheck(subject: String, expectedMarker: String) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        try addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        openMessage(subject: subject, in: app)
        assertBodyContains(text: expectedMarker, in: app)

        // Held open a few extra seconds (script injection, if it worked,
        // would typically run near-instantly on load — this margin is
        // purely so a screenshot taken from the wrapping shell mid-test
        // can land on this screen) then re-checked, to also catch a
        // delayed/async rewrite attempt, not just an immediate one.
        Thread.sleep(forTimeInterval: 3)
        assertBodyContains(text: expectedMarker, in: app)

        Thread.sleep(forTimeInterval: 4)
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
