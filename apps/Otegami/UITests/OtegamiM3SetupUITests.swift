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
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        try addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)

        // 「明日の打ち合わせについて」 collapses into its "Re:" thread row under
        // M4 threading — see OtegamiM1VerificationUITests's matching note.
        // M10: checked newest-sorting-first (Ｆｗｄ) to oldest
        // (ようこそ) so `waitForSeededSubjectScrollingIfNeeded`'s scrolling
        // is monotonic — see its doc comment for why a scroll is needed at
        // all now.
        for subject in ["Ｆｗｄ：今月のリリースノート", "Re: 明日の打ち合わせについて", "ようこそ otegami へ"] {
            XCTAssertTrue(
                waitForSeededSubjectScrollingIfNeeded(subject, in: app),
                "Expected seeded message \"\(subject)\" to appear in the INBOX list before M3 phases run"
            )
        }
    }
}
