import XCTest

/// Offline half of M2's verification: run *after* the dev mailstack has
/// been stopped and `OtegamiM2VerificationUITests` has already opened both
/// seeded HTML messages in the same simulator/app install, so their bodies
/// are cached in local GRDB (`bodyState == .fetched`).
///
/// A cold relaunch lands on the message list, not the message itself —
/// `RootView`'s "last opened thread" restoration is deliberately
/// same-session-only now, not cross-launch (`OtegamiApp.swift`'s
/// `hasSkippedInitialRestoration` doc comment explains the real-device bug
/// that came from restoring straight into `ThreadDetailView` on every cold
/// launch). So this test taps the row itself instead of relying on
/// restoration to get there — arguably a more faithful "offline" check
/// anyway, the same steps a user would actually take. What it still proves
/// is unchanged: the message's body renders from local GRDB storage alone,
/// with the mail server unreachable — no account re-add, no network. See
/// `scripts/verify-ios-m2.sh` for how this fits into the full run.
final class OtegamiM2OfflineVerificationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPreviouslyOpenedMessageBodyRendersOffline() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        // The list itself is a pure GRDB read — renders with no network
        // needed, same guarantee `scripts/verify-ios-m1.sh` already
        // exercises for the offline mailbox list.
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20), "Expected the offline message list to render from local storage alone")

        // 06-html-external-image.eml — the last message
        // `OtegamiM2VerificationUITests` opened before the mailstack went
        // down.
        let predicate = NSPredicate(format: "label CONTAINS %@", "【otegami】新機能のお知らせ")
        let row = list.cells.containing(predicate).firstMatch
        // QA sweep: newer seed fixtures (17/18) can push this one off the
        // initial screen — see `waitForElementScrollingIfNeeded`'s doc
        // comment.
        XCTAssertTrue(waitForElementScrollingIfNeeded(row, in: app), "Expected the previously-opened seeded message to still be listed offline")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        // Its plain-text alternative part contains this line. Matches
        // whether it ends up rendered via the HTML web view or (if it had
        // no HTML part) plain `Text` — either way the text is exposed to
        // the accessibility tree somewhere under a static text label.
        let bodyPredicate = NSPredicate(format: "label CONTAINS %@", "otegami の新機能")
        let bodyText = app.staticTexts.matching(bodyPredicate).firstMatch
        XCTAssertTrue(
            bodyText.waitForExistence(timeout: 20),
            "Expected the previously-fetched message body to render offline from local storage alone"
        )

        // Hold the message open for the wrapping shell script's mid-test
        // screenshot (same technique as M6/M8) — a cold relaunch no longer
        // lands here automatically, so the screenshot has to happen while
        // this test is still running.
        Thread.sleep(forTimeInterval: 4)
    }
}
