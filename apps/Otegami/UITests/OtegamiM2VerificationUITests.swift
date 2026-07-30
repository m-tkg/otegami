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

    func testHTMLBodyRendersAndExternalImagesAutoDisplayByDefault() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        try addDovecotTest1Account(in: app)
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
        // <img src="http://example.com/..."> — remote images now auto-load
        // by default (`ImageSettingsStore.defaultAutoShowRemote == true`,
        // see docs/settings.md "画像 (B)"), so the "画像を表示" banner
        // should *not* appear. (The banner remains as a manual per-message
        // override for anyone who flips the setting off — not covered by
        // this default-behavior checkpoint.)
        openMessage(subject: "【otegami】新機能のお知らせ", in: app)
        assertBodyContains(text: "新機能についてお知らせします", in: app)
        let banner = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "画像を表示")).firstMatch
        XCTAssertFalse(banner.waitForExistence(timeout: 10), "Remote images auto-display by default now, so the \"画像を表示\" banner should not appear")

        // Hold the message open for the wrapping shell script's mid-test
        // screenshot (same technique as `OtegamiM8AttachmentUITests`/
        // `OtegamiM8CIDImageUITests`) — a *cold relaunch* no longer shows
        // this message automatically (`RootView`'s "last opened thread"
        // restoration is now same-session-only, not cross-launch; see
        // `OtegamiApp.swift`'s `hasSkippedInitialRestoration` doc comment),
        // so `scripts/verify-ios-m2.sh` can't screenshot this after the
        // test process exits the way it used to.
        Thread.sleep(forTimeInterval: 4)
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
        // QA sweep: newer seed fixtures (17/18) can push an older subject
        // off the initial screen — see `waitForElementScrollingIfNeeded`'s
        // doc comment.
        XCTAssertTrue(waitForElementScrollingIfNeeded(row, in: app), "Expected seeded message \"\(subject)\" to appear in the INBOX list")
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
