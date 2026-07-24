import XCTest

/// M5 verification, phase 1: add the Dovecot `test1` account with its SMTP
/// fields also filled in (pointing at the dev mailstack's Mailpit) and
/// confirm the SMTP connection test succeeds, then confirm the pre-M5
/// baseline (seeded messages) still renders — the same "add account, list
/// appears" shape M1/M3/M4's own setup phases use.
final class OtegamiM5SetupUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddAccountWithSMTPAndBaselineAppears() throws {
        let app = XCUIApplication()
        app.launch()

        addDovecotTest1AccountWithSMTP(in: app)
        restartAppToRecoverTouchDelivery(app)

        XCTAssertTrue(
            app.staticTexts["ようこそ otegami へ"].waitForExistence(timeout: 30),
            "Expected the seeded baseline message to appear after account setup"
        )
    }
}
