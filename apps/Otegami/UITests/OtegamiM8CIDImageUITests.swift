import XCTest

/// M8 verification, phase 2 (b): open the cid-inline-image HTML seed
/// message (`16-cid-inline-image.eml`), confirm the surrounding HTML text
/// renders (proving the message loaded and the `WKWebView` navigated
/// successfully), and confirm the "画像を表示" external-image banner does
/// *not* appear — this message has no `http(s)://` references at all, only
/// a `cid:` one, so the banner's absence demonstrates the inline image path
/// is independent of (and unaffected by) the external-resource block, per
/// the plan's "外部画像ブロックとは独立に動くこと". The actual rendered image
/// itself (as opposed to broken-image icon) isn't something XCUITest's
/// accessibility tree can assert on inside a `WKWebView` — `verify-ios-m8.sh`
/// screenshots this message open for a human/Claude visual read, the same
/// pattern M2 already established for HTML rendering checks.
final class OtegamiM8CIDImageUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCIDInlineImageMessageRendersWithoutExternalImageBanner() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        // No `popBackOnceIfNeeded` here — `RootView`'s "last opened
        // thread" restoration is same-session-only now (docs/verify.md),
        // so a fresh launch with an existing account always starts
        // *already on* the message list. Popping here would overshoot
        // past the list to the sidebar instead.
        let list = app.collectionViews["messageList.list"]
        let row = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "インライン画像つきHTMLメール")).firstMatch
        XCTAssertTrue(
            waitForElementScrollingIfNeeded(row, in: app),
            "Expected the cid-inline-image seed message to appear"
        )
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        // `HTMLMessageView`'s WKWebView content surfaces as static text in
        // the accessibility tree (M2's established pattern) — search with
        // `CONTAINS` across all static texts rather than a scoped/exact
        // lookup, per verify.md's M2 note on WebKit's accessibility
        // grouping being unpredictable.
        let bodyText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "cid 解決は成功です")).firstMatch
        XCTAssertTrue(bodyText.waitForExistence(timeout: 20), "Expected the cid-image message's HTML body text to render")

        XCTAssertFalse(
            app.buttons["messageDetail.showImagesBanner"].exists,
            "The external-image banner should not appear for a message with only a cid: reference, no http(s):// ones"
        )

        // Hold the message open for the wrapping shell script's mid-test
        // screenshot (same technique as `OtegamiM8AttachmentUITests`).
        Thread.sleep(forTimeInterval: 4)
    }
}
