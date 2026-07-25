import XCTest

/// M6 verification, phase 2: the iCloud account-creation form (plan:
/// "iCloud フォームでプリセットが適用され"). Only the form's own UI/preset
/// values are asserted — actually tapping "接続テスト"/"保存して同期開始" would
/// dial the real `imap.mail.me.com` with fake credentials, which needs
/// network access this environment doesn't guarantee and would just fail
/// authentication anyway (there's no throwaway iCloud account yet — see
/// `PENDING.md`'s "iCloud App 用パスワードでの実アカウント確認" entry).
final class OtegamiM6ICloudFormUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testICloudFormShowsThePresetHostsAndAcceptsInput() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        let emptyStateButton = app.buttons["mail.addAccountButton"]
        let addAccountChip = app.buttons["mail.chip.addAccount"]
        XCTAssertTrue(
            emptyStateButton.waitForExistence(timeout: 10) || addAccountChip.waitForExistence(timeout: 10),
            "Neither the empty-state nor chip-row \"add account\" button appeared"
        )
        (emptyStateButton.exists ? emptyStateButton : addAccountChip).tap()

        let icloudButton = app.buttons["accountTypeSelection.icloudButton"]
        XCTAssertTrue(icloudButton.waitForExistence(timeout: 5), "iCloud button did not appear")
        icloudButton.tap()

        let emailField = app.textFields["icloudAccountSetup.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5), "iCloud account setup form did not appear")

        let imapPreset = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "imap.mail.me.com")).firstMatch
        XCTAssertTrue(imapPreset.waitForExistence(timeout: 5), "Expected the IMAP preset (imap.mail.me.com:993) to be shown")
        let smtpPreset = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "smtp.mail.me.com")).firstMatch
        XCTAssertTrue(smtpPreset.exists, "Expected the SMTP preset (smtp.mail.me.com:587) to be shown")

        // The connection test / save buttons stay disabled until both
        // fields are filled — confirms the form wires its own validation
        // the same way AccountSetupView's does, without needing a real
        // network round trip to prove it.
        let testButton = app.buttons["icloudAccountSetup.testConnectionButton"]
        XCTAssertTrue(testButton.exists)
        XCTAssertFalse(testButton.isEnabled, "Connection test should be disabled before email/app password are entered")

        emailField.tap()
        emailField.typeText("tester@icloud.com")
        let passwordField = app.secureTextFields["icloudAccountSetup.appPassword"]
        passwordField.tap()
        passwordField.typeText("abcd-efgh-ijkl-mnop")

        XCTAssertTrue(testButton.isEnabled, "Connection test should become enabled once email/app password are filled")

        let appPasswordLink = app.links["icloudAccountSetup.appPasswordLink"]
        XCTAssertTrue(appPasswordLink.exists, "Expected the appleid.apple.com app-password link to be shown")

        // See OtegamiM6TypeSelectionUITests's matching comment: this sheet
        // isn't persisted state, so `scripts/verify-ios-m6.sh` screenshots
        // it from a second shell during this pause rather than after this
        // test process exits.
        Thread.sleep(forTimeInterval: 4)
    }
}
