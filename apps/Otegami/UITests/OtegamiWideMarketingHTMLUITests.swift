import XCTest

/// 実機フィードバック第3弾 (B) verification: opens `26-marketing-wide-html.eml`
/// (参考画像1相当 — a full `<html><head>...<meta name="viewport"
/// content="width=900">...</head><body>` document with a 900px fixed-width
/// wrapper table and a 900x300 image) and holds the screen so the wrapping
/// shell script can screenshot it — mirrors `OtegamiHTMLDisplayUITests`'s
/// structure/helpers. The pass/fail signal for "did the fix work" is
/// visual (compare against `docs/verify.md`'s B note and 参考画像1/2), not
/// something this XCUITest itself asserts — `HTMLDocumentBuilder
/// .extractBodyContent(from:)`'s whole point is to neutralize the
/// original's *conflicting* viewport meta, which isn't something the
/// accessibility tree can directly confirm (WKWebView content is opaque to
/// XCUITest beyond its rendered text — `docs/verify.md`'s M2 section).
final class OtegamiWideMarketingHTMLUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testWideMarketingHTMLRenders() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        // A freshly `simctl erase`d simulator has never decided this app's
        // notification authorization yet, and `AppEnvironment
        // .startObservingAccounts()`'s `ValueObservation` fires once
        // immediately even with zero accounts — so
        // `BadgeCenter.requestAuthorizationIfNeeded()` (G「実機フィード
        // バック第3弾」) can pop the system "Would Like to Send You
        // Notifications" prompt right at launch, *before* any account
        // exists. Left unhandled, it sits on top of everything and every
        // subsequent `waitForExistence` times out silently (confirmed by a
        // run that hung for 10+ minutes with this prompt visible in every
        // captured frame). Checked here, immediately after launch — not
        // after `addDovecotTest1Account` — since that's the actual trigger
        // point; same helper `OtegamiM9PushSettingsUITests`/
        // `OtegamiPushSimulatedSetupUITests` already use for the identical
        // prompt. A no-op if it never appears (e.g. a re-run against a
        // simulator install that already decided this).
        allowNotificationPermissionIfNeeded(timeout: 10)

        // Reuses whichever account is already present in this simulator
        // install (added by a previous phase/run) when there is one —
        // added defensively only if the list is empty — so a re-run against
        // an already-set-up install doesn't need to repeat the ~60s account-
        // setup flow (and its own notification-prompt timing risk) just to
        // re-check this one message's rendering.
        let list = app.collectionViews["messageList.list"]
        if !list.waitForExistence(timeout: 5) {
            try addDovecotTest1Account(in: app)
            allowNotificationPermissionIfNeeded(timeout: 10)
            restartAppToRecoverTouchDelivery(app)
        }
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        openMessage(subject: "新春セールのお知らせ", in: app)
        assertBodyContains(text: "いつもotegami Shop", in: app)
        // Let the WKWebView finish laying out/painting before capturing —
        // `assertBodyContains` only proves the text node exists in the
        // accessibility tree, not that the page has visually settled.
        Thread.sleep(forTimeInterval: 2)

        // Attaches the screenshot directly into the test's own xcresult
        // bundle (`.keepAlways` — otherwise a *passing* test's attachments
        // get discarded) rather than relying on a host-side shell script
        // racing this test's `Thread.sleep` window with `xcrun simctl io
        // screenshot` (this suite's own history: that race repeatedly
        // landed on account-setup or the post-teardown home screen instead
        // of the message screen — see this file's earlier revisions/
        // `scripts/verify-ios-b-html-render.sh`). `XCTAttachment` runs
        // in-process, so there's no timing race at all: the extra `xcrun
        // xcresulttool get --legacy` step needed to pull it back out to a
        // plain PNG only has to happen once, after the test finishes.
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "wide-marketing-html-message"
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
