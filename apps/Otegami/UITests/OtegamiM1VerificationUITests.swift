import XCTest

/// Drives the real app against the dev mailstack's Dovecot (`dev/mailstack`,
/// seeded via `make mailstack-seed`) for M1's automated verification
/// checkpoint: add a generic IMAP account, confirm the connection test
/// succeeds, and confirm the seeded INBOX messages show up in the message
/// list. See `Scripts/verify-ios-m1.sh` for how this fits into the full
/// verification run (including the offline checkpoint, which happens after
/// this test via `simctl`, not inside it — see that script's comments).
///
/// Requires `make mailstack-up && make mailstack-seed` to have been run
/// against a mail stack reachable from the simulator at `localhost:1143`
/// (the simulator shares the host's network namespace, so this is the
/// host's `localhost`, not the simulator's).
final class OtegamiM1VerificationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddDovecotAccountAndSyncINBOX() throws {
        let app = XCUIApplication()
        app.launch()

        openAccountSetup(in: app)
        fillDovecotAccountForm(in: app)
        runConnectionTest(in: app)
        saveAccount(in: app)
        assertSeededINBOXMessagesAppear(in: app)
    }

    // MARK: - Steps

    private func openAccountSetup(in app: XCUIApplication) {
        // Empty-state button (first launch) or the toolbar "+" (already has
        // accounts, e.g. re-running this test without resetting the
        // simulator) — whichever is present.
        let emptyStateButton = app.buttons["sidebar.addAccountButton"]
        let toolbarButton = app.buttons["sidebar.addAccountToolbarButton"]
        XCTAssertTrue(
            emptyStateButton.waitForExistence(timeout: 10) || toolbarButton.waitForExistence(timeout: 10),
            "Neither the empty-state nor toolbar \"add account\" button appeared"
        )
        (emptyStateButton.exists ? emptyStateButton : toolbarButton).tap()

        XCTAssertTrue(app.textFields["accountSetup.displayName"].waitForExistence(timeout: 5), "Account setup sheet did not appear")
    }

    private func fillDovecotAccountForm(in app: XCUIApplication) {
        type("Dovecot Test1", into: app.textFields["accountSetup.displayName"])
        type("test1@otegami.test", into: app.textFields["accountSetup.email"])
        type("localhost", into: app.textFields["accountSetup.imapHost"])
        type("1143", into: app.textFields["accountSetup.imapPort"], clearingExisting: true)

        app.buttons["accountSetup.imapSecurity"].tap()
        app.buttons["なし (平文)"].tap()

        type("test1@otegami.test", into: app.textFields["accountSetup.imapUsername"], clearingExisting: true)
        type("test1234", into: app.secureTextFields["accountSetup.password"])
    }

    private func runConnectionTest(in app: XCUIApplication) {
        let testButton = app.buttons["accountSetup.testConnectionButton"]
        XCTAssertTrue(testButton.isEnabled, "Test-connection button should be enabled once the form is filled")
        testButton.tap()

        let result = app.staticTexts["accountSetup.testResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 15), "Connection test result did not appear")
        XCTAssertTrue(result.label.contains("成功"), "Expected a success message, got: \(result.label)")
    }

    private func saveAccount(in app: XCUIApplication) {
        let saveButton = app.buttons["accountSetup.saveButton"]
        XCTAssertTrue(saveButton.isEnabled, "Save button should be enabled after a successful connection test")
        saveButton.tap()

        // The sheet dismisses once the account row + Keychain password are
        // saved; its absence is the signal the save completed.
        XCTAssertTrue(
            app.textFields["accountSetup.displayName"].waitForNonExistence(timeout: 5),
            "Account setup sheet did not dismiss after saving"
        )
    }

    private func assertSeededINBOXMessagesAppear(in app: XCUIApplication) {
        // Subjects from dev/mailstack/seed/fixtures/{01,02,03,04}-*.eml
        // (test1@otegami.test's INBOX; 05-test2-welcome.eml seeds
        // test2@otegami.test instead). Generous timeout: this covers
        // connect + LIST + SELECT + envelope fetch for the initial sync
        // kicked off right after saving.
        let expectedSubjects = [
            "ようこそ otegami へ",
            "明日の打ち合わせについて",
            "Re: 明日の打ち合わせについて",
            "Ｆｗｄ：今月のリリースノート",
        ]
        for subject in expectedSubjects {
            XCTAssertTrue(
                app.staticTexts[subject].waitForExistence(timeout: 30),
                "Expected seeded message \"\(subject)\" to appear in the INBOX list"
            )
        }
    }

    // MARK: - Helpers

    private func type(_ text: String, into element: XCUIElement, clearingExisting: Bool = false) {
        element.tap()
        if clearingExisting, let value = element.value as? String, !value.isEmpty {
            let deleteKeys = String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)
            element.typeText(deleteKeys)
        }
        element.typeText(text)
    }
}

extension XCUIElement {
    /// The inverse of `waitForExistence`: polls until the element is gone
    /// (or the timeout elapses), for asserting a sheet dismissed.
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !exists
    }
}
