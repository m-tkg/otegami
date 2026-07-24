import XCTest

/// M6 verification, phase 3: the plan's "「その他」経路が従来通り動く (dev/mailstack
/// で M1 相当のログイン成功まで)" checkpoint. `AccountTypeSelectionView` now sits
/// in front of every account-creation flow (see `AccountEntryRoute`'s doc
/// comment), so this proves the M1-era "add a Dovecot account, seeded mail
/// appears" behavior is unchanged now that reaching `AccountSetupView`
/// requires one extra tap ("その他 (IMAP)") first —
/// `openAccountSetup(in:)`/`addDovecotTest1Account(in:)` (`DovecotAccountUITestHelpers`)
/// already do that extra tap internally, so this test body is otherwise
/// identical to `OtegamiM1VerificationUITests`.
final class OtegamiM6OtherAccountFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOtherIMAPFlowStillReachesTheSeededInbox() throws {
        let app = XCUIApplication()
        app.launch()

        addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)

        XCTAssertTrue(
            app.staticTexts["ようこそ otegami へ"].waitForExistence(timeout: 30),
            "Expected the seeded baseline message to appear after adding the account via \"その他 (IMAP)\""
        )
    }
}
