import XCTest

/// Account edit UI automated verification (`docs/roadmap.md`'s former
/// "アカウント編集 UI" entry). Three phases, each its own `xcodebuild test
/// -only-testing:` invocation (`scripts/verify-ios-account-edit.sh`) so the
/// wrapping script can screenshot mid-test (the account-edit screen, like
/// M6's account-type-selection sheet, is pure navigation state — nothing
/// here is GRDB-persisted, so a post-test screenshot would just show
/// whatever's underneath):
///
///   1. `testAddAccountAndRenameDisplayName` — add the Dovecot `test1`
///      account, open its edit screen, confirm email/種類 are shown
///      read-only and the form is pre-filled, run "接続テスト" (reusing
///      `AccountSetupView`'s connection-test helper — `AccountConnectionTesting.swift`),
///      rename it, save, confirm the account list reflects the new name.
///   2. `testSavingWrongPasswordSurfacesASyncError` — edit the same
///      account's password to something wrong and save (account-edit
///      saving is **not** gated on a successful connection test, unlike
///      the add-account flow — see `AccountEditView`'s doc comment), then
///      confirm a visible sync-failure banner appears once the
///      automatically-restarted `IDLE` loop's reconnect attempt fails
///      against the wrong password (`AccountRecord.lastSyncError`).
///   3. `testFixingThePasswordRecoversSync` — put the correct password
///      back, save, confirm the banner clears once the next connection
///      attempt succeeds.
///
/// All three rely on the same mechanism this feature added:
/// `AppEnvironment.updateAccount` invalidates the account's cached
/// `SyncEngine.AccountSyncer` and bumps `updatedAt`, and `OtegamiApp`'s
/// existing `.onChange(of: environment.accounts)` (already present for a
/// brand-new account) restarts the `IDLE` loop with the freshly-saved
/// credentials — no relaunch is needed between saving a password and
/// seeing the resulting success/failure, which is why phases 2 and 3 each
/// poll for the banner appearing/disappearing within the same app process
/// that saved the edit, not across a relaunch.
final class OtegamiAccountEditUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddAccountAndRenameDisplayName() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)
        XCTAssertTrue(
            waitForSeededSubjectScrollingIfNeeded("ようこそ otegami へ", in: app),
            "Expected the seeded baseline message before exercising account edit"
        )

        openAccountEditScreen(in: app)

        // Email and kind are shown, but not editable (no TextField/Picker
        // for either) — `LabeledContent`'s rendering combines the label and
        // value into one accessible element, so a `CONTAINS` match on the
        // static text is what actually finds it (M2/M4/M7's recurring
        // "exact-identifier lookups can fail on a visible element" pattern,
        // sidestepped the same way those tests already do — see
        // `.claude/skills/verify/SKILL.md`).
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "test1@otegami.test")).firstMatch.waitForExistence(timeout: 5),
            "email should be shown read-only"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "その他")).firstMatch.waitForExistence(timeout: 5),
            "account kind should be shown read-only"
        )

        // Rename while the top of the form (still scrolled to its initial
        // position) has `accountEdit.displayName` in view — done before
        // scrolling down for "接続テスト" below, not after, so this field
        // access never needs its own scroll-into-view dance.
        let displayNameField = app.textFields["accountEdit.displayName"]
        XCTAssertTrue(displayNameField.waitForExistence(timeout: 5))
        type("Dovecot Test1 Renamed", into: displayNameField, clearingExisting: true)

        // Reuses AccountSetupView's connection-test helper
        // (AccountConnectionTesting.swift) — confirm it also works from
        // this form, pre-filled with the account's existing (correct)
        // Dovecot settings. "接続テスト" sits at the very bottom of a long
        // `Form` (email/kind/displayName, IMAP fields, the whole SMTP
        // section, ahead of it) — like M4's `LazyVStack` pitfall, a `Form`
        // (a `UICollectionView` under the hood on iOS) doesn't mount an
        // off-screen row into the accessibility tree until it's scrolled
        // into view, so a bare `waitForExistence` never finds it without
        // scrolling first.
        let testButton = app.buttons["accountEdit.testConnectionButton"]
        scrollAccountEditFormUntilVisible(testButton, in: app)
        XCTAssertTrue(testButton.exists, "接続テスト button never scrolled into view")
        testButton.tap()
        let testResult = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "成功")).firstMatch
        XCTAssertTrue(testResult.waitForExistence(timeout: 15), "connection test from the edit form should succeed against the still-correct password")

        let saveButton = app.buttons["accountEdit.saveButton"]
        scrollAccountEditFormUntilVisible(saveButton, in: app)
        XCTAssertTrue(saveButton.exists, "保存 button never scrolled into view")
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()

        XCTAssertTrue(displayNameField.waitForNonExistence(timeout: 5), "edit screen did not pop back to the account list after saving")
        XCTAssertTrue(
            app.staticTexts["Dovecot Test1 Renamed"].waitForExistence(timeout: 10),
            "account list did not reflect the renamed display name"
        )

        // Pure navigation state (the Settings sheet's account list) — hold
        // it up for the wrapping script's background screenshot subshell,
        // same pattern M6/M7 established (see this type's doc comment).
        Thread.sleep(forTimeInterval: 4)
    }

    func testSavingWrongPasswordSurfacesASyncError() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        // The account from phase 1 is already on disk; this phase only
        // needs to reach the settings sheet, not re-add anything.
        XCTAssertTrue(
            waitForSeededSubjectScrollingIfNeeded("ようこそ otegami へ", in: app),
            "Expected phase 1's account/messages to still be present"
        )

        openAccountEditScreen(in: app)

        let passwordField = app.secureTextFields["accountEdit.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        type("wrong-password-1234", into: passwordField)

        let saveButton = app.buttons["accountEdit.saveButton"]
        scrollAccountEditFormUntilVisible(saveButton, in: app)
        XCTAssertTrue(saveButton.exists, "保存 button never scrolled into view")
        XCTAssertTrue(saveButton.isEnabled, "save must not be gated on a successful connection test")
        saveButton.tap()
        dismissSavePasswordPromptIfNeeded(timeout: 2)

        XCTAssertTrue(
            app.textFields["accountEdit.displayName"].waitForNonExistence(timeout: 5),
            "edit screen did not pop back to the account list after saving a (deliberately wrong) password"
        )

        // The account's IDLE loop restarts automatically (`OtegamiApp`'s
        // `.onChange(of: environment.accounts)`) with the now-wrong
        // password and fails to connect almost immediately against the
        // dev mailstack's Dovecot — no relaunch needed, see this type's
        // doc comment.
        let syncErrorBanner = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "syncErrorBanner"))
            .firstMatch
        XCTAssertTrue(syncErrorBanner.waitForExistence(timeout: 30), "expected a visible sync-error banner after saving a wrong password")

        Thread.sleep(forTimeInterval: 4)
    }

    func testFixingThePasswordRecoversSync() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        // Phase 2 left the account with a wrong password and a visible
        // sync-error banner; this launch's own scenePhase-active sync
        // attempt will also fail (expected) before this phase fixes it.
        openAccountEditScreen(in: app)

        let passwordField = app.secureTextFields["accountEdit.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        type("test1234", into: passwordField)

        let saveButton = app.buttons["accountEdit.saveButton"]
        scrollAccountEditFormUntilVisible(saveButton, in: app)
        XCTAssertTrue(saveButton.exists, "保存 button never scrolled into view")
        saveButton.tap()
        dismissSavePasswordPromptIfNeeded(timeout: 2)

        XCTAssertTrue(
            app.textFields["accountEdit.displayName"].waitForNonExistence(timeout: 5),
            "edit screen did not pop back to the account list after saving the corrected password"
        )

        let syncErrorBanner = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "syncErrorBanner"))
            .firstMatch
        XCTAssertTrue(
            syncErrorBanner.waitForNonExistence(timeout: 30),
            "expected the sync-error banner to clear once the corrected password connects successfully"
        )

        Thread.sleep(forTimeInterval: 4)
    }

    /// Navigates from wherever the app just launched to the renamed (or
    /// still-original, in phase 1 before the rename) account's edit screen
    /// — a `NavigationLink` push, not a sheet (see `AccountsSettingsView`'s
    /// doc comment on why a nested `.sheet` doesn't work here): 新画面構成,
    /// "設定" is reached via the hamburger menu's bottom row rather than a
    /// tab or a gear-icon sheet, so this opens that first and taps the
    /// account row (found via its `.row`-suffixed identifier — see
    /// `AccountsSettingsView`'s doc comment on why that suffix exists — with
    /// a `CONTAINS` match since only one account is ever present in this
    /// suite), then waits for `AccountEditView`'s screen to appear.
    private func openAccountEditScreen(in app: XCUIApplication) {
        openSettingsFromHamburgerMenu(in: app)

        // `.any` (not `.buttons`): a `NavigationLink` row's exposed
        // accessibility type isn't guaranteed to be `.button` the way a
        // plain `Button`'s is — matching broadly here is what actually
        // finds it reliably in this simulator/toolchain.
        let accountRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", ".row"))
            .firstMatch
        XCTAssertTrue(accountRow.waitForExistence(timeout: 10), "account row not found in the settings list")
        accountRow.tap()

        // `.collectionViews`, not `.otherElements`: the identifier sits on
        // `AccountEditView`'s `Form` directly (no wrapping `NavigationStack`
        // — see that view's doc comment), and a `Form`/`List` on iOS is
        // exposed to XCUITest as a `UICollectionView`, unlike
        // `AccountSetupView`'s `.sheet`-root identifier (an `Other`,
        // sitting one level up on the `NavigationStack` itself). Confirmed
        // via `app.debugDescription` while diagnosing an earlier failure
        // here — the screen was rendering correctly the whole time
        // (`accountEdit.email`/`.displayName`/`.imapHost` etc. all present
        // and correctly pre-filled); only this query's element type was
        // wrong.
        XCTAssertTrue(app.collectionViews["accountEdit.screen"].waitForExistence(timeout: 10), "account edit screen did not appear")
    }

    /// Scrolls `AccountEditView`'s `Form` (identifier `accountEdit.screen`,
    /// a `UICollectionView` — see `openAccountEditScreen`'s doc comment)
    /// downward, a bit at a time, until `element` exists — the general form
    /// of `DovecotAccountUITestHelpers.waitForElementScrollingIfNeeded`,
    /// which is hardcoded to `messageList.list` and so can't be reused for
    /// this screen's own scroll container.
    @discardableResult
    private func scrollAccountEditFormUntilVisible(_ element: XCUIElement, in app: XCUIApplication, maxScrollAttempts: Int = 10) -> Bool {
        var found = element.waitForExistence(timeout: 5)
        let form = app.collectionViews["accountEdit.screen"]
        var scrollAttempts = 0
        while !found && scrollAttempts < maxScrollAttempts {
            // `.swipeUp()` (the built-in convenience gesture), not a
            // hand-rolled `coordinate(...).press(forDuration:thenDragTo:)`
            // — the latter never actually scrolled this particular `Form`
            // (confirmed: 10 attempts, ~2 minutes, zero movement, diagnosed
            // while building this test), unlike `messageList.list`'s plain
            // `List`, which the coordinate-drag approach scrolls just fine
            // (`DovecotAccountUITestHelpers.waitForElementScrollingIfNeeded`).
            // M3's swipe-actions pitfall documents the opposite asymmetry
            // for a different gesture (`.swipeLeft()`/`.swipeRight()`
            // working where a hand-rolled drag didn't) — same underlying
            // lesson: prefer the built-in convenience gesture over
            // reimplementing it with raw coordinates in this
            // simulator/toolchain, and don't assume one gesture's working
            // technique transfers to a different view type.
            form.swipeUp()
            found = element.waitForExistence(timeout: 2)
            scrollAttempts += 1
        }
        return found
    }
}
