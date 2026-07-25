import XCTest

/// M6 verification, phase 1: the account-type picker itself (plan: "種別選択:
/// Gmail / iCloud / その他 (IMAP)"). Runs with no `GOOGLE_OAUTH_CLIENT_ID`
/// configured (the CI/dev default — see `docs/oauth-setup.md`), so this
/// specifically exercises the "Client ID 未設定時に Gmail ボタン無効 + 案内表示"
/// checkpoint from the plan; a real interactive Google sign-in is out of
/// automated-verification scope (see `PENDING.md`).
final class OtegamiM6TypeSelectionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAllThreeAccountTypesAreOfferedAndGmailIsDisabledWithoutAClientId() throws {
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

        XCTAssertTrue(app.otherElements["accountTypeSelection.sheet"].waitForExistence(timeout: 5) || app.buttons["accountTypeSelection.otherButton"].waitForExistence(timeout: 5), "Account type selection sheet did not appear")

        let gmailButton = app.buttons["accountTypeSelection.gmailButton"]
        XCTAssertTrue(gmailButton.waitForExistence(timeout: 5), "Gmail button should exist even when disabled")
        XCTAssertFalse(gmailButton.isEnabled, "Gmail button should be disabled without GOOGLE_OAUTH_CLIENT_ID configured")

        let hint = app.staticTexts["accountTypeSelection.gmailDisabledHint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "Expected the docs/oauth-setup.md hint to be visible while Gmail is disabled")
        XCTAssertTrue(hint.label.contains("oauth-setup.md"), "Expected the hint to point at docs/oauth-setup.md, got: \(hint.label)")

        let icloudButton = app.buttons["accountTypeSelection.icloudButton"]
        XCTAssertTrue(icloudButton.exists, "iCloud button should exist")
        XCTAssertTrue(icloudButton.isEnabled, "iCloud button should always be enabled (no Client ID needed)")

        let otherButton = app.buttons["accountTypeSelection.otherButton"]
        XCTAssertTrue(otherButton.exists, "\"その他 (IMAP)\" button should exist")
        XCTAssertTrue(otherButton.isEnabled, "\"その他\" button should always be enabled")

        // `scripts/verify-ios-m6.sh` screenshots this sheet from a second
        // shell while this pause runs (the sheet itself isn't
        // GRDB-persisted state, so a screenshot taken *after* this test
        // process exits — the pattern every other verify script uses per
        // docs/verify.md — would just show whatever's underneath instead).
        Thread.sleep(forTimeInterval: 4)
    }

    func testCancelDismissesTheTypeSelectionSheet() throws {
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

        let cancelButton = app.buttons["accountTypeSelection.cancelButton"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Cancel button did not appear")
        cancelButton.tap()

        XCTAssertTrue(
            app.buttons["accountTypeSelection.otherButton"].waitForNonExistence(timeout: 5),
            "Account type selection sheet did not dismiss after Cancel"
        )
    }
}
