import XCTest

/// M3 verification, phase 1: add the Dovecot account and confirm the
/// baseline seeded INBOX (M1's four plain-text fixtures) renders, exactly
/// like `OtegamiM1VerificationUITests` — this phase exists separately (run
/// first by `scripts/verify-ios-m3.sh`, deliberately *not* terminating the
/// app afterward) so the account/mailbox state it establishes is in place
/// before the script injects new mail from the host and runs the later M3
/// phases (`OtegamiM3NewMailUITests`, `OtegamiM3SwipeActionsUITests`)
/// against it.
final class OtegamiM3SetupUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddAccountAndBaselineListAppears() throws {
        let app = XCUIApplication()
        app.launch()

        addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)

        for subject in ["ようこそ otegami へ", "明日の打ち合わせについて", "Ｆｗｄ：今月のリリースノート"] {
            XCTAssertTrue(
                app.staticTexts[subject].waitForExistence(timeout: 30),
                "Expected seeded message \"\(subject)\" to appear in the INBOX list before M3 phases run"
            )
        }
    }
}
