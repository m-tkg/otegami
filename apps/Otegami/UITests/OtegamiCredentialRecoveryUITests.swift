import XCTest

/// Reproduces the actual root cause behind a real-device report: after the
/// duplicate-account merge fix landed (`docs/icloud-sync.md`'s "重複挿入バグ"),
/// the surviving account still showed "資格情報を待っています" and mail wouldn't
/// open. Investigating found commit `52df393` ("use com.mtkg as the bundle
/// identifier prefix everywhere") had silently changed
/// `KeychainCredentialStore`'s *default* `service` string from
/// `"com.m-tkg.otegami.account-password"` to
/// `"com.mtkg.otegami.account-password"` — a hardcoded Swift literal
/// completely independent of `PRODUCT_BUNDLE_IDENTIFIER`, so every password
/// stored before that commit became invisible to every lookup after it
/// (`kSecAttrService` is part of a Keychain item's identity, not a freely
/// re-queryable label). See `KeychainCredentialStore.legacyServices`'s doc
/// comment for the full account.
///
/// This suite drives the real recovery path end to end: add a real account
/// (its password lands under the *current* service, same as any real
/// device), relocate it onto the *legacy* service string
/// (`KeychainCredentialStore.relocateToLegacyServiceForUITesting`, reached
/// via `OTEGAMI_UITEST_MOVE_CREDENTIALS_TO_LEGACY_KEYCHAIN_SERVICE`,
/// simulating "this device's password predates the rename"), then relaunch
/// and confirm `AppEnvironment.init()`'s normal startup sync
/// (`OtegamiApp.startIdleLoops`, which calls `AppEnvironment.auth(for:)` for
/// every account on every cold launch) recovers the password transparently
/// — no "資格情報を待っています" banner, no user action required — instead of
/// the account getting silently orphaned the way a real device's did.
final class OtegamiCredentialRecoveryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPasswordRecoversFromLegacyKeychainServiceOnRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        try addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        // Relaunch once more, this time asking `AppEnvironment.init()` to
        // relocate the account's already-saved password onto the legacy
        // Keychain service string *before* anything else in that same
        // launch touches it — reproducing exactly the state a real device
        // was left in by the service-string rename.
        app.terminate()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_MOVE_CREDENTIALS_TO_LEGACY_KEYCHAIN_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15), "The message list should still appear normally after the relocated-credential launch")

        // The account should show no pending-credential banner — proof the
        // legacy-service fallback in `KeychainCredentialStore
        // .password(forAccountId:)` found and returned the relocated
        // password during this launch's normal startup sync
        // (`OtegamiApp.startIdleLoops` → `AppEnvironment.auth(for:)`),
        // migrating it back onto the current service in the process.
        // Without the fix, this launch's `auth(for:)` call would find
        // nothing under the current service, set `needsReauth = true`, and
        // this banner would appear instead.
        openSettingsFromHamburgerMenu(in: app)
        // I「設定画面の再構成」: アカウント一覧 (バナーもここに含まれる) は
        // 「アカウントの設定」カテゴリの下 — 遷移しないとバナー不在の
        // アサーションが空振りで常に true になってしまう。
        XCTAssertTrue(navigateToAccountSettingsCategory(in: app), "「アカウントの設定」カテゴリへの遷移に失敗した")

        let pendingCredentialBanner = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "資格情報を待っています")).firstMatch
        XCTAssertFalse(
            pendingCredentialBanner.waitForExistence(timeout: 8),
            "No pending-credential banner should show once KeychainCredentialStore's legacy-service fallback recovered the relocated password"
        )

        // A message never opened before this point should still load its
        // real body over the network, not the missing-credential message.
        returnToMailTabRootIfNeeded(in: app)
        openMessage(subject: "ようこそ otegami へ", in: app)
        let missingCredentialText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "資格情報がありません")).firstMatch
        XCTAssertFalse(missingCredentialText.waitForExistence(timeout: 10), "The recovered credential should let the body fetch succeed instead of failing with a missing-credential error")
    }

    /// Reproduces the *other* real-device shape this rescue covers: a
    /// device that already went through a bad duplicate-account merge
    /// before this fix shipped — the merge picked (or the pre-fix code
    /// left) a survivor account with no working Keychain credential, while
    /// the merged-away account's real password is still sitting, orphaned,
    /// in the Keychain under an accountId no `AccountRecord` references
    /// anymore. `AppEnvironment.init()`'s `adoptOrphanedCredentialIfUnambiguous`
    /// (see its doc comment, and `docs/icloud-sync.md`) is supposed to
    /// detect and repair this automatically on the very next ordinary
    /// launch — no duplicate-merge flag, no user action — as long as the
    /// situation is unambiguous (exactly one `.password` account missing a
    /// credential, exactly one orphaned Keychain item).
    func testOrphanedCredentialIsAdoptedOnNextOrdinaryLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        try addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        // Relaunch once more, this time asking `AppEnvironment.init()` to
        // relocate the account's already-saved password onto a synthetic
        // orphan accountId *before* anything else in that same launch
        // touches it — reproducing exactly the end state a real device was
        // left in by a bad duplicate-account merge (survivor with no
        // credential, real password stranded under a now-nonexistent id).
        app.terminate()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_RELOCATE_CREDENTIAL_TO_ORPHAN_ACCOUNT_ID"] = "1"
        app.launch()

        // A perfectly ordinary third launch — no special flags — is what's
        // supposed to notice the orphan and reassign it.
        app.terminate()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15), "The message list should still appear normally after the orphan-adoption launch")

        openSettingsFromHamburgerMenu(in: app)
        // I「設定画面の再構成」: アカウント一覧 (バナーもここに含まれる) は
        // 「アカウントの設定」カテゴリの下 — 遷移しないとバナー不在の
        // アサーションが空振りで常に true になってしまう。
        XCTAssertTrue(navigateToAccountSettingsCategory(in: app), "「アカウントの設定」カテゴリへの遷移に失敗した")

        let pendingCredentialBanner = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "資格情報を待っています")).firstMatch
        XCTAssertFalse(
            pendingCredentialBanner.waitForExistence(timeout: 8),
            "No pending-credential banner should show once AppEnvironment's orphan-adoption rescue reassigned the stranded password back to this account"
        )

        returnToMailTabRootIfNeeded(in: app)
        openMessage(subject: "ようこそ otegami へ", in: app)
        let missingCredentialText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "資格情報がありません")).firstMatch
        XCTAssertFalse(missingCredentialText.waitForExistence(timeout: 10), "The adopted credential should let the body fetch succeed instead of failing with a missing-credential error")
    }

    private func openMessage(subject: String, in app: XCUIApplication) {
        let list = app.collectionViews["messageList.list"]
        let predicate = NSPredicate(format: "label CONTAINS %@", subject)
        let row = list.cells.containing(predicate).firstMatch
        XCTAssertTrue(waitForElementScrollingIfNeeded(row, in: app), "Expected seeded message \"\(subject)\" to appear in the INBOX list")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
    }
}
