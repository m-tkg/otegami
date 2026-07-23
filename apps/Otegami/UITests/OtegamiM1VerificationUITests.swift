import XCTest

/// Drives the real app against the dev mailstack's Dovecot (`dev/mailstack`,
/// seeded via `make mailstack-seed`) for M1's automated verification
/// checkpoint: add a generic IMAP account, confirm the connection test
/// succeeds, and confirm the seeded INBOX messages show up in the message
/// list. See `Scripts/verify-ios-m1.sh` for how this fits into the full
/// verification run (including the offline checkpoint, which happens after
/// this test via `simctl`, not inside it — see that script's comments).
///
/// Requires `make mailstack-up && make mailstack-seed` to have been run
/// against a mail stack reachable from the simulator at `localhost:1143`
/// (the simulator shares the host's network namespace, so this is the
/// host's `localhost`, not the simulator's).
final class OtegamiM1VerificationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddDovecotAccountAndSyncINBOX() throws {
        let app = XCUIApplication()
        app.launch()

        addDovecotTest1Account(in: app)
        assertSeededINBOXMessagesAppear(in: app)
    }

    private func assertSeededINBOXMessagesAppear(in app: XCUIApplication) {
        // Subjects from dev/mailstack/seed/fixtures/{01,02,03,04}-*.eml
        // (test1@otegami.test's INBOX; 05-test2-welcome.eml seeds
        // test2@otegami.test instead, and 06/07 are M2's HTML fixtures —
        // not asserted here, see OtegamiM2VerificationUITests). Generous
        // timeout: this covers connect + LIST + SELECT + envelope fetch
        // for the initial sync kicked off right after saving.
        let expectedSubjects = [
            "ようこそ otegami へ",
            "明日の打ち合わせについて",
            "Re: 明日の打ち合わせについて",
            "Ｆｗｄ：今月のリリースノート",
        ]
        for subject in expectedSubjects {
            XCTAssertTrue(
                app.staticTexts[subject].waitForExistence(timeout: 30),
                "Expected seeded message \"\(subject)\" to appear in the INBOX list"
            )
        }
    }
}
