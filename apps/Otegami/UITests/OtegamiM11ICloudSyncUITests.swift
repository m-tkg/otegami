import XCTest

/// M11 (iCloud account sync, docs/icloud-sync.md) automated verification.
///
/// A real two-device iCloud KVS round trip can't be driven from a single
/// simulator (`PENDING.md` has the manual two-device checklist), so what
/// *is* automatable and matters most for regression purposes is: the app
/// launches at all with the new `com.apple.developer.ubiquity-kvstore
/// -identifier` entitlement in place (a launch-time crash here would be
/// the iOS/macOS equivalent of M10's "App Group entitlement missing"
/// postmortem), the new "iCloud でアカウントを同期" toggle is reachable and
/// on by default, and adding an account the old-fashioned way still works
/// unchanged with the entitlement present.
final class OtegamiM11ICloudSyncUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCloudSyncToggleIsShownAndOnByDefault() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        // 新画面構成: "設定" is reached via the hamburger menu's bottom row
        // now, not a tab bar or a gear-icon sheet off the old sidebar.
        openSettingsFromHamburgerMenu(in: app)
        // 実機フィードバック第3弾 (I): iCloud 同期は「アカウントの設定」
        // カテゴリの下 (旧「その他」カテゴリは廃止)。
        XCTAssertTrue(navigateToAccountSettingsCategory(in: app), "「アカウントの設定」カテゴリへの遷移に失敗した")

        let toggle = app.switches["settings.cloudSyncToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        // XCUIElement.value for a `Toggle` is "1"/"0" — see this project's
        // other on/off assertions on `Switch` elements for the same
        // pattern (none pre-existing at time of writing, so spelled out
        // here rather than referenced).
        XCTAssertEqual(toggle.value as? String, "1", "iCloud sync should default to on")

        // M6's screenshot pattern: the settings sheet is pure navigation
        // state (nothing here is GRDB-persisted), so a screenshot taken
        // after this test method returns would just show whatever's
        // underneath. Hold the screen up for `verify-ios-icloud.sh`'s
        // background screenshot subshell instead (see M6's verify script
        // doc comment / `.claude/skills/verify/SKILL.md`'s M6 section for
        // why a single fixed-delay screenshot is unreliable and this
        // repeated-overwrite approach is used instead).
        Thread.sleep(forTimeInterval: 4)
    }

    func testTogglingCloudSyncOffAndBackOnDoesNotCrashOrLoseTheAccountList() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        try addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)

        XCTAssertTrue(
            waitForSeededSubjectScrollingIfNeeded("ようこそ otegami へ", in: app),
            "Expected the seeded baseline message to still appear after adding an account with the iCloud sync entitlement present"
        )

        // 新画面構成: "設定" is reached via the hamburger menu's bottom row.
        openSettingsFromHamburgerMenu(in: app)
        // 実機フィードバック第3弾 (I): iCloud 同期は「アカウントの設定」
        // カテゴリの下 (旧「その他」カテゴリは廃止)。
        XCTAssertTrue(navigateToAccountSettingsCategory(in: app), "「アカウントの設定」カテゴリへの遷移に失敗した")

        let toggle = app.switches["settings.cloudSyncToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        // Deliberately not asserting the exact "0"/"1" `Switch.value`
        // after each tap here — this simulator/toolchain's `Switch`
        // controls have proven unreliable to read a same-frame value
        // change from in other parts of this app's verification history
        // (`.claude/skills/verify/SKILL.md`'s recurring "tap registers,
        // visible state doesn't" class of issue). What this test needs to
        // prove is the thing that actually matters for a regression check:
        // toggling doesn't crash the app or corrupt/lose the account list.
        // `testCloudSyncToggleIsShownAndOnByDefault` above already covers
        // the default-on value itself.
        toggle.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "app should still be alive and responsive after toggling off")
        toggle.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "app should still be alive and responsive after toggling back on")

        // Toggling off then back on runs a full reconcile
        // (`AppEnvironment.setCloudSyncEnabled`) — this should be a no-op
        // for an account that's already pushed to the cloud and matches,
        // not something that duplicates or drops it. "設定" is a permanent
        // tab now (no sheet to close) — a full relaunch is still the most
        // reliable way to confirm the account survived, reading straight
        // from GRDB on a cold launch rather than trusting any in-memory
        // state a toggle round trip could have disturbed.
        restartAppToRecoverTouchDelivery(app)
        XCTAssertTrue(
            waitForSeededSubjectScrollingIfNeeded("ようこそ otegami へ", in: app),
            "Expected the account/message list to survive a cloud-sync toggle off/on round trip"
        )
    }
}
