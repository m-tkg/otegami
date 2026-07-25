import XCTest

/// M5 verification, phase 4 (offline send → replay): two XCUITest classes,
/// run by `scripts/verify-ios-m5.sh` with `make mailstack-down`/`-up`
/// interleaved between them (the same "inject state from the host, then
/// launch/relaunch the app to observe it" pattern `verify-ios-m3.sh`
/// established for offline scenarios — see `verify.md`'s note on why a live
/// "stay foregrounded, watch it recover" XCUITest isn't achievable: the
/// wrapping shell script's `docker compose`/`make` calls need to run from a
/// plain host process, not from inside the sandboxed XCUITest).
///
/// `OtegamiM5OfflineComposeUITests` composes and sends while the mailstack
/// is down: `OpQueueProcessor.replay`'s own IMAP `connect()` fails before
/// touching any op, so the `.send` op (and its `outboxMessage` row) stays
/// queued — `FolderListSheet`'s "送信待ち" row (design-phase-2: the old
/// sidebar's equivalent row, now inside the folder-picker sheet) is what
/// proves that queuing happened, entirely from local state, no network
/// involved.
final class OtegamiM5OfflineComposeUITests: XCTestCase {
    /// Shared with `scripts/verify-ios-m5.sh` — see `OtegamiM5ComposeSendUITests
    /// .subject`'s doc comment.
    static let subject = "otegami M5 オフライン送信テスト"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testComposeWhileOfflineShowsPendingOutbox() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        returnToMailTabRootIfNeeded(in: app)

        let composeButton = app.buttons["mail.composeButton"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 10))
        composeButton.tap()

        let toField = app.textFields["composer.to"]
        XCTAssertTrue(toField.waitForExistence(timeout: 10))
        type("recipient@otegami.test", into: toField)
        type(Self.subject, into: app.textFields["composer.subject"])

        let bodyField = app.textViews["composer.body"]
        bodyField.tap()
        bodyField.typeText("オフライン送信テストの本文です。")

        app.buttons["composer.sendButton"].tap()
        XCTAssertTrue(toField.waitForNonExistence(timeout: 15), "Composer sheet should dismiss (local enqueue succeeds even offline)")

        // The best-effort immediate replay attempt fails silently (mailstack
        // down) — the outboxMessage row it couldn't flush is exactly what
        // drives this indicator, now inside the folder-picker sheet.
        XCTAssertTrue(folderSheetShowsOutboxRow(in: app, timeout: 15), "Expected a \"送信待ち\" indicator while offline")
    }
}

/// `OtegamiM5OfflineReplayUITests` relaunches the app after the mailstack
/// is back up — `RootView`'s `scenePhase == .active` handler runs an
/// opQueue replay on every foreground transition/launch (the exact
/// mechanism M3's foreground-IDLE verification already relies on), so a
/// fresh `app.launch()` is sufficient to trigger the queued `.send` op's
/// retry deterministically, without needing a live foregrounded wait.
final class OtegamiM5OfflineReplayUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testReplayClearsThePendingOutboxIndicator() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        returnToMailTabRootIfNeeded(in: app)

        // Polls rather than a single snapshot: the replay itself is
        // asynchronous (kicked off from `RootView.syncAllAccountsOnce()`),
        // and the mailstack having just come back up can still take a
        // moment to accept the connection. Each poll opens/closes
        // `FolderListSheet` since that's the only place "送信待ち" is shown
        // now (design-phase-2) — checked as a fresh open every iteration
        // rather than leaving the sheet up throughout, so this doesn't rely
        // on the sheet re-observing `OutboxQuery` while backgrounded/idle.
        let deadline = Date().addingTimeInterval(20)
        while folderSheetShowsOutboxRow(in: app, timeout: 3), Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertFalse(folderSheetShowsOutboxRow(in: app, timeout: 3), "Expected the \"送信待ち\" indicator to clear once the queued send replayed successfully")
    }
}
