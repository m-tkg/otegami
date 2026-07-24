import XCTest

/// M7 verification, phase 1: adds both dev-mailstack Dovecot accounts
/// (`test1`/`test2`) and confirms their seeded messages are visible before
/// any search-specific phase runs. Kept separate from the search phases
/// (`OtegamiM7SearchUITests`) for the same reason M4/M5/M6 split "add an
/// account" from the checks that use it — `scripts/verify-ios-m7.sh`
/// uninstalls once before this phase for a clean local DB, then every later
/// phase reuses this phase's persisted GRDB state across its own fresh
/// `app.launch()` (`AppDatabase` lives on disk, keyed by the simulator
/// install, not by process lifetime).
final class OtegamiM7SetupUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddingBothAccountsShowsSeededMessages() throws {
        let app = XCUIApplication()
        app.launch()

        addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)

        // No `popBackOnceIfNeeded` here (unlike the second account, below):
        // this is the very first account ever added in this run, so
        // `RootView` has nothing restored to pop back *from* — the restart
        // lands directly on the message list, same as
        // `OtegamiM4SetupUITests`'s first restart.
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ようこそ otegami へ")).firstMatch
                .waitForExistence(timeout: 20),
            "Expected test1's seeded welcome message to appear"
        )

        returnToSidebarRootIfNeeded(in: app)
        addDovecotTest2Account(in: app)
        restartAppToRecoverTouchDelivery(app)

        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.staticTexts["test2 アカウントへようこそ"].waitForExistence(timeout: 20),
            "Expected test2's seeded welcome message to appear in the unified inbox"
        )
    }
}
