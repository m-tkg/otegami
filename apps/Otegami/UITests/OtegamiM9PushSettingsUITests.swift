import XCTest

/// M9 verification: drives the "設定 → プッシュ通知" flow far enough to
/// prove the UI itself works end to end (toggle → consent → enable
/// attempt), then confirms the simulator's inherent limitation (no real
/// APNs device token — `PushTokenCenter`'s doc comment) degrades
/// gracefully to a visible error message rather than a crash/hang.
/// Doesn't need any account added first — the enable flow's "create a
/// watch per `.password` account" step is simply a no-op with zero
/// accounts, which is fine for what this test is checking.
///
/// This suite assumes the local build has a relay URL configured
/// (`Config/Local.xcconfig`'s `OTEGAMI_PUSH_RELAY_URL`, git-ignored) — the
/// same assumption `docs/verify.md`'s M9 section already documents for
/// every other push-settings UITest/verify script in this repo. A build
/// with no relay configured shows a disabled toggle instead
/// (`RelayURLConfig.isConfigured == false`,
/// `PushNotificationSettingsView.statusSection`'s doc comment) that this
/// suite doesn't attempt to drive — there is no environment-variable/
/// launch-argument override for that build-time value to exercise it from
/// a UITest without a second scheme, and OSS contributors running this
/// suite without their own relay configured are expected to skip it (same
/// as `OtegamiPushSimulatedSetupUITests`'s own precondition).
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
        // Task #212: プッシュ通知は「アカウントの設定」カテゴリから「一般」
        // カテゴリへ再移設された (旧: 実機フィードバック第3弾 (I) で
        // 「その他」カテゴリ廃止時に「アカウントの設定」へ移設していた)。
        XCTAssertTrue(navigateToGeneralSettingsCategory(in: app), "「一般」カテゴリへの遷移に失敗した")

        app.buttons["settings.pushNotificationsLink"].tap()

        // Task #212 (実機フィードバック「iOS で Push の on/off は
        // Enable/Disable の文字ではなく通常の on/off トグルにして」):
        // 「有効にする」ボタンは標準の`Toggle`に置き換わった。
        let enabledToggle = app.switches["settings.push.enabledToggle"]
        XCTAssertTrue(enabledToggle.waitForExistence(timeout: 10))
        XCTAssertEqual(enabledToggle.value as? String, "0", "push should start disabled")
        enabledToggle.tap()

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
        // `pushEnabledBinding`'s doc comment: the toggle's `get` always
        // reflects `environment.isPushEnabled`, so a failed enable attempt
        // must leave it showing OFF (no local optimistic state to revert).
        XCTAssertEqual(enabledToggle.value as? String, "0", "push should not report itself enabled on the simulator")
    }
}
