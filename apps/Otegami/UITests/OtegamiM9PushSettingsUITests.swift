import XCTest

/// M9 verification: drives the "設定 → プッシュ通知" flow far enough to
/// prove the UI itself works end to end (URL validation → consent →
/// enable attempt), then confirms the simulator's inherent limitation
/// (no real APNs device token — `PushTokenCenter`'s doc comment) degrades
/// gracefully to a visible error message rather than a crash/hang.
/// Doesn't need any account added first — the enable flow's "create a
/// watch per `.password` account" step is simply a no-op with zero
/// accounts, which is fine for what this test is checking.
final class OtegamiM9PushSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEnablingPushOnSimulatorShowsGracefulDegradationMessage() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        // 新画面構成: "設定" is reached via the hamburger menu's bottom row.
        openSettingsFromHamburgerMenu(in: app)

        app.staticTexts["プッシュ通知"].tap()

        let relayURLField = app.textFields["settings.push.relayURLField"]
        XCTAssertTrue(relayURLField.waitForExistence(timeout: 10))
        relayURLField.tap()
        relayURLField.typeText("https://relay.example.com")

        let enableButton = app.buttons["settings.push.enableButton"]
        XCTAssertTrue(enableButton.waitForExistence(timeout: 5))
        XCTAssertTrue(enableButton.isEnabled, "enable button should be enabled once a valid https:// URL is entered")
        enableButton.tap()

        // The consent alert (plan: explicit opt-in wording about
        // credentials being sent to/stored on the relay). `.firstMatch`
        // rather than the identifier subscript: SwiftUI's `.alert` button
        // accessibility identifier is seen to match more than one element
        // in this simulator/toolchain (the alert itself is presented in a
        // system-owned window, distinct from the app-window touch-delivery
        // quirks documented in .claude/skills/verify/SKILL.md, but the
        // same "query broadly, don't require exactly one match" workaround
        // applies).
        let consentConfirm = app.buttons["settings.push.consentConfirmButton"].firstMatch
        XCTAssertTrue(consentConfirm.waitForExistence(timeout: 10), "expected the credential-sharing consent alert")
        consentConfirm.tap()

        // Simulators never issue a real APNs device token, so
        // AppEnvironment.enablePushNotifications always surfaces
        // .noDeviceToken here — PushNotificationSettingsView turns that
        // into a visible, non-crashing error message rather than hanging
        // or silently doing nothing.
        let errorMessage = app.staticTexts["settings.push.errorMessage"]
        XCTAssertTrue(
            errorMessage.waitForExistence(timeout: 40),
            "expected a graceful-degradation error message on the simulator (no APNs token available)"
        )
        XCTAssertFalse(app.staticTexts["settings.push.enabledLabel"].exists, "push should not report itself enabled on the simulator")
    }

    func testEnableButtonDisabledForInvalidRelayURL() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        // 新画面構成: "設定" is reached via the hamburger menu's bottom row —
        // see the previous test method's comment.
        openSettingsFromHamburgerMenu(in: app)
        app.staticTexts["プッシュ通知"].tap()

        let relayURLField = app.textFields["settings.push.relayURLField"]
        XCTAssertTrue(relayURLField.waitForExistence(timeout: 10))
        relayURLField.tap()
        // http (non-localhost) is rejected by AppEnvironment.validatedRelayURL.
        relayURLField.typeText("http://relay.example.com")

        let enableButton = app.buttons["settings.push.enableButton"]
        XCTAssertTrue(enableButton.waitForExistence(timeout: 5))
        XCTAssertFalse(enableButton.isEnabled, "enable button should stay disabled for a non-https, non-localhost URL")
    }
}
