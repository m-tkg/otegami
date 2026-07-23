import XCTest

/// Drives the real app against the dev mailstack's Dovecot for M2's
/// automated verification checkpoint: opening a message fetches and shows
/// its body, HTML messages render with external images blocked by default
/// (and a "画像を表示" banner to unblock them), and a message read once
/// stays readable offline. See `scripts/verify-ios-m2.sh` for how this
/// fits into the full run (including the offline restart, which happens
/// after this test via `simctl`, not inside it — mirroring M1's split
/// between "assert via XCUITest" and "screenshot for visual review").
///
/// Requires `make mailstack-up && make mailstack-seed` to have been run
/// (see `OtegamiM1VerificationUITests`'s doc comment for why `localhost`
/// reaches the host's Docker-published Dovecot from the simulator).
final class OtegamiM2VerificationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHTMLBodyRendersAndExternalImagesAreBlockedByDefault() throws {
        let app = XCUIApplication()
        app.launch()

        addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        // 07-html-only-japanese.eml: no text/plain part at all — this
        // only renders if BodyFetcher's HTML→plainText fallback and the
        // HTML web view both work, and MailCore2 decoded the Japanese
        // body correctly.
        openMessage(subject: "HTML版だより", in: app)
        assertBodyContains(text: "こんにちは、otegami です。", in: app)
        assertBodyContains(text: "HTML 専用", in: app)

        returnToMessageList(in: app)

        // 06-html-external-image.eml: multipart/alternative with an
        // <img src="http://example.com/..."> — the "画像を表示" banner
        // should appear (blocked by default) and disappear once tapped.
        openMessage(subject: "【otegami】新機能のお知らせ", in: app)
        // Identifier-based lookup (`app.buttons["messageDetail
        // .showImagesBanner"]`) never matches here even while the banner
        // is plainly visible on screen (confirmed via screenshot taken
        // mid-poll) — the same kind of accessibility-identifier lookup
        // quirk `openMessage` above already works around for row cells.
        // A label-text predicate finds it reliably instead.
        let banner = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "画像を表示")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "Expected the \"画像を表示\" banner for a message with an external image")
        banner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        XCTAssertTrue(banner.waitForNonExistence(timeout: 10), "Banner should disappear once external content is allowed")
    }

    // MARK: - Steps

    private func openMessage(subject: String, in app: XCUIApplication) {
        // `XCUIElement.tap()` internally does a "scroll to visible, then
        // compute a hit point" dance that reliably produces an invalid
        // `{-1, -1}` hit point for this row in this simulator — even
        // though the row's own reported frame is valid and already
        // on-screen (confirmed by printing it: `.tap()` still fails after
        // "Retrying failed scroll-to-visible..."). Tapping an explicit
        // `XCUICoordinate` derived directly from the element's frame
        // bypasses that broken scroll-to-visible path entirely.
        let list = app.collectionViews["messageList.list"]
        let predicate = NSPredicate(format: "label CONTAINS %@", subject)
        let row = list.cells.containing(predicate).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Expected seeded message \"\(subject)\" to appear in the INBOX list")
        // A brief press (rather than an instantaneous `tap()`/coordinate
        // tap) gives the List's scroll-view-based tap-vs-scroll gesture
        // disambiguation time to actually recognize it as a tap.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
    }

    /// On a compact-width layout, `List(selection:)` pushes the detail pane
    /// atop the message list (`NavigationSplitView`'s standard compact-size
    /// behavior) — tapping the navigation bar's back button returns to it.
    /// On a wide (multi-column) layout the list stays visible and there's
    /// no back button to find, so this is a no-op there.
    private func returnToMessageList(in app: XCUIApplication) {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.waitForExistence(timeout: 3) {
            backButton.tap()
        }
    }

    /// Asserts `text` appears somewhere in the message detail pane —
    /// either as a plain SwiftUI `Text` (`messageDetail.plainTextBody`) or
    /// inside the `WKWebView` (`messageDetail.htmlWebView`), whichever the
    /// message rendered as. WebKit content is exposed to the accessibility
    /// tree as (possibly multi-line-grouped) static text, so `CONTAINS`
    /// against every static text label is more robust than expecting an
    /// exact-match element for one paragraph.
    private func assertBodyContains(text: String, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let element = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "Expected message body to contain \"\(text)\"")
    }
}
