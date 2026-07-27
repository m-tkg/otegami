import XCTest

/// Task #48 (デフォルトメールアプリ対応): confirms a `mailto:` URL actually
/// reaches `OtegamiApp.handleOpenURL(_:)` and prefills the Composer, end to
/// end through the real OS URL-routing path — not just `MailtoURLParser`'s
/// own unit tests (`packages/OtegamiKit/Tests/OtegamiCoreTests
/// /MailtoURLParserTests.swift`), which never touch `CFBundleURLTypes`/
/// `.onOpenURL` at all.
///
/// Same two-phase shape as `OtegamiPushSimulatedNotificationReadUITests`
/// (that file's own doc comment explains why): this XCUITest process runs
/// *inside* the simulator and can't shell out to `xcrun simctl` itself
/// (`Foundation.Process` is unavailable there) — the wrapping host script
/// (`scripts/verify-ios-mailto.sh`) launches the app, then runs
/// `xcrun simctl openurl booted 'mailto:...'` from the host between two
/// separate `xcodebuild test -only-testing:` invocations. This phase
/// (`testMailtoOpenPrefillsComposer`) is the *second* one — it assumes the
/// app is already in the foreground with the Composer sheet already open
/// from that `simctl openurl` call, and only reads/asserts the resulting
/// field values.
final class OtegamiMailtoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Reattaches to the already-running app (no `app.launch()` — a fresh
    /// launch here would blow away the very state this phase exists to
    /// read) and asserts the Composer's To/Cc/Bcc/subject/body match the
    /// `mailto:` URL `scripts/verify-ios-mailto.sh` opens:
    /// `mailto:a@otegami.test,b@otegami.test?cc=c@otegami.test&bcc=d@otegami.test&subject=...&body=...`
    func testMailtoOpenPrefillsComposer() throws {
        dismissSpringboardOpenInOtegamiAlertIfPresent()

        let app = XCUIApplication()
        app.activate()

        let toField = app.textFields["composer.to"]
        XCTAssertTrue(toField.waitForExistence(timeout: 15), "Composer sheet should already be open from the mailto: URL")
        XCTAssertEqual(toField.value as? String, "a@otegami.test, b@otegami.test")
        XCTAssertEqual(app.textFields["composer.cc"].value as? String, "c@otegami.test")
        XCTAssertEqual(app.textFields["composer.bcc"].value as? String, "d@otegami.test")
        XCTAssertEqual(app.textFields["composer.subject"].value as? String, "mailtoテスト")

        let bodyView = app.textViews["composer.body"]
        XCTAssertTrue(bodyView.waitForExistence(timeout: 5))
        XCTAssertEqual(bodyView.value as? String, "本文です")
    }

    /// `xcrun simctl openurl` (the only way this script's host side can
    /// trigger a `mailto:` open at all — `Foundation.Process` being
    /// unavailable to this in-simulator test process, this file's own doc
    /// comment) routes through Springboard's own "Open in “Otegami”?"
    /// consent alert before the URL is actually delivered to the app —
    /// confirmed empirically (`scripts/verify-ios-mailto.sh`'s first manual
    /// run screenshotted exactly this alert instead of the Composer).
    /// Real taps on a `mailto:` link from inside another app (Safari,
    /// Notes, ...) show the same system consent alert for a non-http(s)
    /// custom scheme, so this isn't a `simctl`-only artifact — it's the
    /// realistic path a real link tap goes through too, just happening to
    /// be host-triggered here instead of user-triggered.
    private func dismissSpringboardOpenInOtegamiAlertIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let openButton = springboard.buttons["Open"]
        if openButton.waitForExistence(timeout: 5) {
            openButton.tap()
        }
    }
}
