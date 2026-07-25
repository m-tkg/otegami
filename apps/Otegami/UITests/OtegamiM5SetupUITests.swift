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
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        addDovecotTest1AccountWithSMTP(in: app)
        restartAppToRecoverTouchDelivery(app)

        // M10: `waitForSeededSubjectScrollingIfNeeded` — see its doc
        // comment (dev/mailstack's seed fixture set grew enough across
        // M2-M8 that this, the oldest-dated fixture, no longer fits on
        // the first screen without scrolling).
        XCTAssertTrue(
            waitForSeededSubjectScrollingIfNeeded("ようこそ otegami へ", in: app),
            "Expected the seeded baseline message to appear after account setup"
        )
    }
}
