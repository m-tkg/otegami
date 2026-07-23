import XCTest

/// Offline half of M2's verification: run *after* the dev mailstack has
/// been stopped and `OtegamiM2VerificationUITests` has already opened both
/// seeded HTML messages in the same simulator/app install (so their bodies
/// are cached in local GRDB, `bodyState == .fetched`, and the last-opened
/// one is remembered via `RootView`'s "lastOpenedMessage" `@AppStorage`
/// restoration — see `OtegamiApp.swift`). A cold relaunch here shows that
/// message's body again straight from local storage — no account re-add,
/// no tap, no network — confirmed via screenshot: the app opens directly
/// to the message detail pane with the full body rendered while the
/// mailstack is down. See `scripts/verify-ios-m2.sh` for how this fits
/// into the full run.
final class OtegamiM2OfflineVerificationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPreviouslyOpenedMessageBodyRendersOffline() throws {
        let app = XCUIApplication()
        app.launch()

        // The last message OtegamiM2VerificationUITests opened before the
        // mailstack went down: 06-html-external-image.eml, whose
        // plain-text alternative part contains this line. Matches whether
        // it ends up rendered via the HTML web view or (if it had no HTML
        // part) plain `Text` — either way the text is exposed to the
        // accessibility tree somewhere under a static text label.
        let predicate = NSPredicate(format: "label CONTAINS %@", "otegami の新機能")
        let element = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: 20),
            "Expected the last-opened message's body to render offline from local storage alone"
        )
    }
}
