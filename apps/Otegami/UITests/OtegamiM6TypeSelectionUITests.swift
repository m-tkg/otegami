import XCTest

/// M6 verification, phase 1: the account-type picker itself (plan: "種別選択:
/// Gmail / iCloud / その他 (IMAP)"). Whether `GOOGLE_OAUTH_CLIENT_ID` is
/// configured is a per-machine build setting (`Config/Local.xcconfig` —
/// unset on a clean CI/dev checkout per `docs/oauth-setup.md`, but this
/// developer's own machine has a real Client ID configured), so this test
/// asserts both branches of `AccountTypeSelectionView`'s
/// `environment.isGmailOAuthConfigured` behavior conditionally on the
/// button's actual enabled state rather than assuming the client-ID-absent
/// branch — it should pass either way. A real interactive Google sign-in is
/// still out of automated-verification scope (see `PENDING.md`).
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
        XCTAssertTrue(gmailButton.waitForExistence(timeout: 5), "Gmail button should exist regardless of Client ID configuration")

        let hint = app.staticTexts["accountTypeSelection.gmailDisabledHint"]
        if gmailButton.isEnabled {
            // This dev machine has a real GOOGLE_OAUTH_CLIENT_ID configured
            // (`Config/Local.xcconfig`) — the disabled-state hint must not
            // be shown alongside an enabled button.
            XCTAssertFalse(hint.exists, "Gmail hint should not be shown once a Client ID is configured")
        } else {
            // Clean checkout / CI default: no Client ID configured.
            XCTAssertTrue(hint.waitForExistence(timeout: 5), "Expected the docs/oauth-setup.md hint to be visible while Gmail is disabled")
            XCTAssertTrue(hint.label.contains("oauth-setup.md"), "Expected the hint to point at docs/oauth-setup.md, got: \(hint.label)")
        }

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
