import XCTest

/// M3 verification, phase 2 ("差分同期"): `scripts/verify-ios-m3.sh` injects
/// `dev/mailstack/seed/fixtures/08-m3-new-mail.eml` into test1's INBOX via
/// `doveadm save` (standing in for another client delivering new mail)
/// *before* this test runs, then this test does a fresh `app.launch()` and
/// polls for that message's subject to appear.
///
/// A fresh launch is what's actually exercised here (rather than trying to
/// keep a previous test's app process alive across `docker compose exec`
/// calls made from the *host* shell script — `Foundation.Process` isn't
/// available to code compiled for iOS, so the doveadm injection can only
/// happen from the wrapping shell script, between two separate `xcodebuild
/// test` invocations): `RootView`'s `scenePhase == .active` handler runs
/// an opQueue replay + `AccountSyncer.performIncrementalSync` immediately
/// on every foreground transition, including the very first one after
/// launch — the identical code path a live foreground `IDLE` push would
/// also trigger, just invoked deterministically here instead of waiting on
/// a race with the simulator's network stack.
final class OtegamiM3NewMailUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNewMailAppearsAfterForegroundIncrementalSync() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        let subject = "M3差分同期テスト"
        XCTAssertTrue(
            app.staticTexts[subject].waitForExistence(timeout: 30),
            "Expected the doveadm-injected message \"\(subject)\" to appear via the launch-triggered incremental sync"
        )
    }
}
