import XCTest

/// Reproduces a real-device bug report: a `.password` account whose
/// Keychain item goes missing used to fail message body fetch with an
/// opaque, hardcoded "資格情報が見つかりません" error and no visible
/// account-level indicator anywhere. Fixed in `AppEnvironment.auth(for:)`
/// (now sets `needsReauth`, reusing the existing M11 "資格情報を待っています"/
/// "再接続" banner machinery) and, as of the iCloud-sync duplicate-account
/// fix (`docs/icloud-sync.md`), `MessageView
/// .missingCredentialAwareErrorMessage` — rather than leaking the raw
/// `"authenticationFailed: missingCredential"` error text (a second real-
/// device report against the *same* underlying condition, this time
/// reached via a cloud-inserted duplicate account with no local Keychain
/// item), it now shows an actionable Japanese message pointing at the
/// exact Settings banner/button (`AccountsSettingsView`'s "資格情報を待っています"/
/// "再接続") that already exists for this condition. See
/// `MessageView.deleteCredentialIfUITestRequested`'s doc comment for why
/// this needs an internal launch-environment hook rather than driving it
/// through the UI (there's no user action that deletes a Keychain item).
final class OtegamiMissingCredentialUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMissingCredentialShowsRealErrorAndAccountBanner() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_DELETE_CREDENTIAL"] = "1"
        app.launch()

        addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        // A message never opened before this point, so `load()` actually
        // has to hit `fetchBodyOverNetwork` (a message whose body is
        // already cached locally would short-circuit before ever needing
        // `auth(for:)` again) — the credential gets deleted by the hook
        // right as this open starts. Picks the most-recently-dated seed
        // fixture (sorts first, no scrolling needed) rather than an older
        // one — this suite now shares the INBOX with every other feature's
        // fixtures added this session, so a message dated further back can
        // require scrolling past two dozen rows.
        openMessage(subject: "リンクを開くブラウザのテスト", in: app)

        // The actionable "no credential on this device" message should now
        // be visible — not the old fixed "資格情報が見つかりません" string, and
        // not a raw "authenticationFailed: missingCredential" leak either
        // (see `MessageView.missingCredentialAwareErrorMessage`'s doc
        // comment).
        let errorText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "この端末にはこのアカウントの資格情報がありません")).firstMatch
        XCTAssertTrue(errorText.waitForExistence(timeout: 20), "Expected the actionable missing-credential message to be visible, not a generic/raw error")

        // The account should now show the "資格情報を待っています" banner in
        // Settings — the same M11 UI a cloud-synced-but-not-yet-keychain-
        // synced account already used, now also covering this case.
        openSettingsFromHamburgerMenu(in: app)

        let pendingCredentialBanner = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "資格情報を待っています")).firstMatch
        XCTAssertTrue(scrollSettingsUntilVisible(pendingCredentialBanner, in: app), "Expected the 資格情報を待っています banner for the account whose Keychain item was deleted")

        // Real-device bug fix (`docs/icloud-sync.md`): the banner's button
        // used to be labeled "再接続" and just silently re-ran the same
        // automatic Keychain check every launch already performs — for a
        // `.password` account whose credential is genuinely gone (not just
        // "not synced yet"), tapping it did nothing visible at all. It now
        // reads "パスワードを入力" and pushes straight to `AccountEditView`'s
        // password field (`AccountsSettingsView.passwordEntryAccountId`).
        let passwordEntryButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "パスワードを入力")).firstMatch
        XCTAssertTrue(scrollSettingsUntilVisible(passwordEntryButton, in: app), "Expected the pending-credential banner's button to read パスワードを入力, not the old dead-end 再接続")
        passwordEntryButton.tap()

        let passwordField = app.secureTextFields["accountEdit.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "Expected パスワードを入力 to push straight to AccountEditView's password field")

        Thread.sleep(forTimeInterval: 3)
    }

    // MARK: - Steps

    private func openMessage(subject: String, in app: XCUIApplication) {
        let list = app.collectionViews["messageList.list"]
        let predicate = NSPredicate(format: "label CONTAINS %@", subject)
        let row = list.cells.containing(predicate).firstMatch
        XCTAssertTrue(waitForElementScrollingIfNeeded(row, in: app), "Expected seeded message \"\(subject)\" to appear in the INBOX list")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
    }

    private func scrollSettingsUntilVisible(_ element: XCUIElement, in app: XCUIApplication, maxAttempts: Int = 10) -> Bool {
        var found = element.waitForExistence(timeout: 3)
        let list = app.collectionViews.firstMatch
        var attempts = 0
        while !found, attempts < maxAttempts {
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            start.press(forDuration: 0.05, thenDragTo: end)
            found = element.waitForExistence(timeout: 2)
            attempts += 1
        }
        return found
    }
}
