import XCTest

/// Reproduces (then confirms the fix for) a real-device bug report:
/// `test1@otegami.test` showed up **twice** in Settings → アカウント (same
/// email, different `accountId` UUIDs), and opening some messages failed
/// with "本文の取得に失敗しました: authenticationFailed" while others opened fine
/// — see `docs/icloud-sync.md`'s "重複挿入バグ" for the root cause
/// (`AccountCloudSyncEngine.reconcile()` used to match accounts by
/// `accountId` alone, so two devices independently adding "the same"
/// mailbox produced two unrelated-looking account rows once cloud sync
/// reconciled them onto a third device).
///
/// A real two-device iCloud KVS round trip that would *organically*
/// produce this can't be driven from a single simulator (`docs/icloud
/// -sync.md`'s "制限" section, `PENDING.md`). What these three phases do
/// instead is recreate the exact **end state** the bug leaves a device in
/// — two local `account` rows for the same mailbox, one with a working
/// Keychain credential and one `needsReauth` — by injecting a duplicate row
/// directly into the on-disk database via `sqlite3` between phases (the
/// wrapping shell script, `scripts/verify-ios-duplicate-account.sh`, does
/// the injection; this file only drives the app before/after it). That
/// end state is what actually matters for the reported symptoms, so
/// reproducing it directly is a legitimate substitute for the full causal
/// chain — see `OTEGAMI_UITEST_SKIP_DUPLICATE_ACCOUNT_MERGE`'s doc comment
/// on `AppEnvironment.init()` for why phase 2 needs it: without a way to
/// hold the pre-merge state still for one launch, the fix's own
/// synchronous migration (by design) never leaves the bug state visible in
/// the UI for even one frame.
final class OtegamiDuplicateAccountUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Phase 1: add the real `test1@otegami.test` Dovecot account the
    /// ordinary way (real Keychain credential, `needsReauth == false`,
    /// INBOX synced) — the "survivor" the duplicate-merge migration should
    /// keep. The wrapping script injects the duplicate row via `sqlite3`
    /// after this phase completes and the app has been terminated.
    func testPhase1AddRealAccount() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)
        XCTAssertTrue(
            waitForSeededSubjectScrollingIfNeeded("ようこそ otegami へ", in: app),
            "Expected the seeded baseline message to appear before injecting a duplicate account"
        )
    }

    /// Phase 2 ("before"): launched with the duplicate-merge migration
    /// skipped, right after the wrapping script has injected a second
    /// `account` row for the same mailbox (different `accountId`,
    /// `needsReauth = 1`, no matching Keychain item). Asserts the actual
    /// bug: **two** entries for `test1@otegami.test` in Settings, the
    /// second one showing the "資格情報を待っています" banner — exactly what
    /// the real device report described.
    func testPhase2ShowsTheDuplicateBeforeTheFix() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_SKIP_DUPLICATE_ACCOUNT_MERGE"] = "1"
        app.launch()

        app.tabBars.buttons["設定"].tap()
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))

        // `list.waitForExistence` only proves the (possibly still-empty)
        // List container exists, not that `AppEnvironment.accounts`' async
        // `ValueObservation` has delivered its first snapshot into it yet —
        // an immediate, non-retrying `matches.count` check right after can
        // race ahead of that and see 0 rows. Poll instead of trusting the
        // first snapshot.
        let matchCount = waitForAccountRowCount(2, emailText: "test1@otegami.test", in: app)
        XCTAssertEqual(matchCount, 2, "Expected the real device bug: two account rows for the same email address")

        let pendingCredentialBanner = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "資格情報を待っています")).firstMatch
        XCTAssertTrue(scrollSettingsUntilVisible(pendingCredentialBanner, in: app), "Expected the duplicate's needsReauth banner to be visible")

        // Hold the screen for the wrapping script's mid-test screenshot
        // (M6's established pattern — this state isn't GRDB-persisted in a
        // way a post-test screenshot could still catch, since the very
        // next launch resolves it).
        Thread.sleep(forTimeInterval: 4)
    }

    /// Phase 3 ("after"): a completely ordinary launch (no skip flag) of
    /// the exact same on-disk database phase 2 just used — the migration
    /// runs synchronously before this test (or any UI) ever sees the
    /// account list, per `AppEnvironment.init()`'s doc comment. Asserts the
    /// duplicate is gone, exactly one `test1@otegami.test` entry remains
    /// with no pending-credential banner, and — the "no data loss" claim —
    /// the survivor's INBOX still shows the seeded baseline message.
    func testPhase3TheDuplicateIsGoneAfterTheFix() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        app.tabBars.buttons["設定"].tap()
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))

        let matchCount = waitForAccountRowCount(1, emailText: "test1@otegami.test", in: app)
        XCTAssertEqual(matchCount, 1, "Expected the duplicate account merge to have collapsed both rows into one")

        let pendingCredentialBanner = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "資格情報を待っています")).firstMatch
        XCTAssertFalse(pendingCredentialBanner.waitForExistence(timeout: 3), "The surviving account must be the one with a working credential, not the needsReauth duplicate")

        Thread.sleep(forTimeInterval: 2)

        // No data loss: the survivor's synced mail must still be there.
        app.tabBars.buttons["メール"].tap()
        XCTAssertTrue(
            waitForSeededSubjectScrollingIfNeeded("ようこそ otegami へ", in: app),
            "Expected the surviving account's INBOX to still show its synced mail after the merge"
        )
    }

    /// Polls `staticTexts` matching `emailText` until the count stops
    /// changing (or `expected` is reached) — see the two call sites' doc
    /// comments for why a single, non-retrying `matches.count` right after
    /// `list.waitForExistence` is racy: the List container existing proves
    /// nothing about whether `AppEnvironment.accounts`' async
    /// `ValueObservation` has delivered a snapshot into it yet.
    private func waitForAccountRowCount(_ expected: Int, emailText: String, in app: XCUIApplication, maxAttempts: Int = 15) -> Int {
        func currentCount() -> Int {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", emailText)).count
        }
        var count = currentCount()
        var attempts = 0
        while count != expected, attempts < maxAttempts {
            Thread.sleep(forTimeInterval: 0.5)
            count = currentCount()
            attempts += 1
        }
        return count
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
