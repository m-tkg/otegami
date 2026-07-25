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
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
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
        //
        // 02/03 (「明日の打ち合わせについて」/「Re: 明日の打ち合わせについて」) are a
        // References-linked pair (M4): they now collapse into one thread
        // row showing only the latest message's subject
        // ("Re: 明日の打ち合わせについて") plus a count badge, so the bare
        // "明日の打ち合わせについて" text is no longer its own row — only the
        // "Re:" one is asserted here.
        //
        // M10: `seed.sh`'s fixture set grew across M2–M8 (16 fixtures by
        // now, all seeded into the same INBOX together), which pushed
        // "ようこそ otegami へ" (01-welcome.eml, the oldest-dated fixture)
        // down to the *last* row in the newest-first thread list —
        // discovered by actually re-running this script for M10's
        // regression pass, not something these subjects' own content or
        // ordering logic changed. `messageList.list`'s `List` only
        // materializes visible rows (SwiftUI, same as any `LazyVStack`), so
        // a `waitForExistence` with no scroll genuinely can't find a row
        // that's off the bottom of the screen — this isn't the "exact
        // lookup fails on a visible element" pitfall documented elsewhere
        // in docs/verify.md, the row really isn't mounted yet. Scrolling
        // the list down before checking each subject (harmless no-op once
        // a subject is already on screen — `waitForExistence` finds it
        // immediately, no scroll needed) makes this robust to the fixture
        // set growing further.
        let expectedSubjects = [
            "Ｆｗｄ：今月のリリースノート",
            "Re: 明日の打ち合わせについて",
            "ようこそ otegami へ",
        ]
        for subject in expectedSubjects {
            XCTAssertTrue(
                waitForSeededSubjectScrollingIfNeeded(subject, in: app),
                "Expected seeded message \"\(subject)\" to appear in the INBOX list"
            )
        }
    }
}
