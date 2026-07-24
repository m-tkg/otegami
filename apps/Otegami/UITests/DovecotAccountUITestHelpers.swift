import XCTest

/// Shared XCUITest steps for driving the app against the dev mailstack's
/// `test1@otegami.test` Dovecot account through `AccountSetupView`. Used by
/// both `OtegamiM1VerificationUITests` (initial sync) and
/// `OtegamiM2VerificationUITests` (body fetch / HTML rendering) so the
/// "add account" flow isn't duplicated across verification suites.
extension XCTestCase {
    /// Dismisses the simulator's "Save Password?" prompt if it's up. iOS's
    /// Keychain AutoFill heuristic fires after typing into
    /// `accountSetup.password`'s `SecureField` and tapping "保存して同期開始"
    /// (treating it like a submitted login form) — that system alert is
    /// presented by a separate process (not the app under test), so it
    /// silently steals the *next* synthesized tap/query if left up: e.g. a
    /// message-list row tap intended to select a message ends up hitting
    /// the alert instead, leaving the app on the list with no visible
    /// symptom beyond "nothing after this point ever matches".
    /// `addUIInterruptionMonitor` is the documented API for this but is
    /// unreliable for the Password AutoFill sheet specifically in this
    /// simulator/OS combination; querying `com.apple.springboard` directly
    /// is slower to write but deterministic.
    func dismissSavePasswordPromptIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notNow = springboard.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) {
            notNow.tap()
        }
    }

    /// Opens the account-setup sheet, fills in the dev mailstack's `test1`
    /// Dovecot credentials, runs (and asserts) the connection test, and
    /// saves — leaving the sheet dismissed and initial sync kicked off.
    func addDovecotTest1Account(in app: XCUIApplication) {
        openAccountSetup(in: app)
        fillDovecotAccountForm(in: app)
        runConnectionTest(in: app)
        saveAccount(in: app)
        dismissSavePasswordPromptIfNeeded()
    }

    /// Works around a confirmed simulator/OS defect (found while building
    /// `OtegamiM2VerificationUITests`): after `AccountSetupView`'s
    /// `.sheet()` dismisses, every subsequent synthesized tap/press in this
    /// simulator computes an invalid `{-1, -1}` hit point — reproduced even
    /// for a plain toolbar button, not just `List` rows, so it isn't
    /// specific to this app's view structure. `app.activate()` does *not*
    /// clear it; a full terminate+relaunch does. Call this once, right
    /// after `addDovecotTest1Account`, before any test that needs to tap
    /// something beyond the account-setup sheet itself (M1's test never
    /// taps after that point, which is why it never hit this). The
    /// account/mailbox are already persisted in GRDB, so relaunching
    /// resumes on the same INBOX list with nothing to re-enter.
    func restartAppToRecoverTouchDelivery(_ app: XCUIApplication) {
        app.terminate()
        app.launch()
    }

    /// M4: adds the dev mailstack's second seeded account (`test2
    /// @otegami.test`) — used by the unified-inbox verification, which
    /// needs a second account already present. Assumes `test1` (or no
    /// account at all) is already the sidebar's state, so `openAccountSetup`
    /// finds whichever of the empty-state/toolbar "add account" buttons is
    /// currently showing.
    func addDovecotTest2Account(in app: XCUIApplication) {
        openAccountSetup(in: app)
        fillDovecotAccountForm(
            in: app,
            displayName: "Dovecot Test2",
            email: "test2@otegami.test",
            username: "test2@otegami.test",
            password: "test1234"
        )
        runConnectionTest(in: app)
        saveAccount(in: app)
        dismissSavePasswordPromptIfNeeded()
    }

    /// Generalized form of `fillDovecotAccountForm(in:)` (below) for any of
    /// the dev mailstack's seeded users, not just `test1`.
    func fillDovecotAccountForm(in app: XCUIApplication, displayName: String, email: String, username: String, password: String) {
        type(displayName, into: app.textFields["accountSetup.displayName"])
        type(email, into: app.textFields["accountSetup.email"])
        type("localhost", into: app.textFields["accountSetup.imapHost"])
        type("1143", into: app.textFields["accountSetup.imapPort"], clearingExisting: true)

        app.buttons["accountSetup.imapSecurity"].tap()
        app.buttons["なし (平文)"].tap()

        type(username, into: app.textFields["accountSetup.imapUsername"], clearingExisting: true)
        type(password, into: app.secureTextFields["accountSetup.password"])
    }

    /// M4: pops back one level (detail → content, i.e. `ThreadDetailView`
    /// → `MessageListView`) via the navigation bar's leading button, for
    /// any test that might launch straight into a restored
    /// `ThreadDetailView` (`RootView`'s "last opened thread" `@AppStorage`
    /// restoration, the same mechanism M2 relies on for its offline
    /// checkpoint) rather than the message list. On this simulator/device
    /// ("iPhone 17 Pro Max") `NavigationSplitView` is compact-width —
    /// sidebar → content → detail is a real push stack with a back button
    /// at each level, not a side-by-side layout. A no-op if no back button
    /// is present (already at the message list, or nothing was ever
    /// opened).
    func popBackOnceIfNeeded(in app: XCUIApplication) {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.waitForExistence(timeout: 5) {
            backButton.tap()
        }
    }

    /// Like `popBackOnceIfNeeded`, but keeps popping (up to 3 times, the
    /// deepest this app's navigation stack ever gets — sidebar → content →
    /// detail) until the sidebar's "add account" entry point (either the
    /// empty-state button or the toolbar one) is reachable — for a test
    /// that needs the sidebar itself (e.g. adding a second account) and
    /// can't assume how many levels deep a restored launch left off at.
    func returnToSidebarRootIfNeeded(in app: XCUIApplication) {
        for _ in 0..<3 {
            if app.buttons["sidebar.addAccountButton"].exists || app.buttons["sidebar.addAccountToolbarButton"].exists {
                return
            }
            let backButton = app.navigationBars.buttons.element(boundBy: 0)
            guard backButton.waitForExistence(timeout: 3) else { return }
            backButton.tap()
        }
    }

    func openAccountSetup(in app: XCUIApplication) {
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

    func fillDovecotAccountForm(in app: XCUIApplication) {
        type("Dovecot Test1", into: app.textFields["accountSetup.displayName"])
        type("test1@otegami.test", into: app.textFields["accountSetup.email"])
        type("localhost", into: app.textFields["accountSetup.imapHost"])
        type("1143", into: app.textFields["accountSetup.imapPort"], clearingExisting: true)

        app.buttons["accountSetup.imapSecurity"].tap()
        app.buttons["なし (平文)"].tap()

        type("test1@otegami.test", into: app.textFields["accountSetup.imapUsername"], clearingExisting: true)
        type("test1234", into: app.secureTextFields["accountSetup.password"])
    }

    /// M5: adds the `test1` Dovecot account with SMTP fields also filled in
    /// (pointing at the dev mailstack's Mailpit, `localhost:1025`, plain —
    /// see `dev/mailstack/compose.yml`) and runs the SMTP connection test
    /// too, so the saved account can actually send. `addDovecotTest1Account`
    /// (above) intentionally leaves SMTP blank — M1–M4's tests don't need
    /// it, and M1's account form documents SMTP as optional-to-save.
    func addDovecotTest1AccountWithSMTP(in app: XCUIApplication) {
        openAccountSetup(in: app)
        fillDovecotAccountForm(in: app)
        runConnectionTest(in: app)
        fillMailpitSMTPFields(in: app)
        runSMTPConnectionTest(in: app)
        saveAccount(in: app)
        dismissSavePasswordPromptIfNeeded()
    }

    /// Fills the SMTP section with the dev mailstack's Mailpit
    /// (`localhost:1025`, plain). Deliberately leaves `smtpUsername`
    /// blank: Mailpit's EHLO doesn't advertise `AUTH` at all and rejects
    /// an attempt outright, and `OpQueueProcessor.smtpAuth`/
    /// `MailCoreSMTPSession.connect` both treat a blank SMTP username as
    /// "this relay needs no authentication" — see their doc comments.
    func fillMailpitSMTPFields(in app: XCUIApplication) {
        type("localhost", into: app.textFields["accountSetup.smtpHost"])
        type("1025", into: app.textFields["accountSetup.smtpPort"], clearingExisting: true)

        app.buttons["accountSetup.smtpSecurity"].tap()
        app.buttons["なし (平文)"].tap()
    }

    func runSMTPConnectionTest(in app: XCUIApplication) {
        let testButton = app.buttons["accountSetup.testSMTPConnectionButton"]
        XCTAssertTrue(testButton.waitForExistence(timeout: 5), "SMTP test button should exist")
        XCTAssertTrue(testButton.isEnabled, "SMTP test button should be enabled once host/port are filled")
        testButton.tap()

        let result = app.staticTexts["accountSetup.smtpTestResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 15), "SMTP connection test result did not appear")
        XCTAssertTrue(result.label.contains("成功"), "Expected an SMTP success message, got: \(result.label)")
    }

    func runConnectionTest(in app: XCUIApplication) {
        let testButton = app.buttons["accountSetup.testConnectionButton"]
        XCTAssertTrue(testButton.isEnabled, "Test-connection button should be enabled once the form is filled")
        testButton.tap()

        let result = app.staticTexts["accountSetup.testResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 15), "Connection test result did not appear")
        XCTAssertTrue(result.label.contains("成功"), "Expected a success message, got: \(result.label)")
    }

    func saveAccount(in app: XCUIApplication) {
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

    func type(_ text: String, into element: XCUIElement, clearingExisting: Bool = false) {
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
    /// (or the timeout elapses), for asserting a sheet dismissed or a
    /// banner was dismissed.
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !exists
    }
}
