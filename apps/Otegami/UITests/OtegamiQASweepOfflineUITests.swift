import XCTest

/// Scenario 4 of the exploratory QA sweep ("オフライン遷移の雑な組合せ"):
/// messy combinations of the mailstack going down/up around local
/// operations, driven by `scripts/verify-qa-sweep-offline.sh` (which
/// controls `make mailstack-up`/`make mailstack-down` between phases —
/// XCUITest itself can't do that, `Foundation.Process` isn't available on
/// iOS, same constraint M3's verification already documented). Assumes the
/// `test1` Dovecot account already exists (added by an earlier phase in
/// the wrapping script, following the same pattern as M3/M4/M5's own
/// multi-phase scripts).
final class OtegamiQASweepOfflineUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Phase: mailstack is *already down* when this launches (cold start
    /// while offline — "down 中のまま起動→操作" from the task's scenario
    /// list). The app must still come up on local GRDB data alone, and
    /// ordinary navigation (scroll, open a thread) must keep working with
    /// no network reachable at all.
    func testColdLaunchWhileOfflineThenNavigate() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "Expected the message list reachable even with the mailstack down")

        let list = app.collectionViews["messageList.list"]
        list.swipeUp()
        list.swipeDown()

        let firstRow = list.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20), "Expected the offline message list to still show cached content")
        firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        XCTAssertTrue(app.scrollViews["threadDetail.scrollView"].waitForExistence(timeout: 20), "Expected opening a thread to work from local storage alone while offline")
    }

    /// Phase: mailstack still down. Marks "HTML版だより" read via a leading
    /// swipe while offline — must apply optimistically to the local list
    /// immediately, with nothing to replay against yet.
    ///
    /// Deliberately *not* the newest seed message (`18-empty-body.eml`,
    /// "本文が空のメール"): the previous phase
    /// (`testColdLaunchWhileOfflineThenNavigate`) opens whichever thread
    /// sorts first — the newest, i.e. that exact message — and opening a
    /// thread auto-marks it read (`MessageView.markAsReadIfNeeded()`).
    /// Swiping *that* message here would then be toggling an
    /// already-(locally, offline-)read message back to unread, not marking
    /// an unread one read — not a bug, just two enqueued ops (add-seen from
    /// opening it, remove-seen from this swipe) racing to define the same
    /// message's final state, and easy to misread as "the offline read
    /// never reached the server" when it's actually "the *last* offline op
    /// against this message correctly reached the server, and that op
    /// happened to be the swipe's undo." Confirmed by direct GRDB
    /// inspection (`sqlite3` against the simulator's `otegami.sqlite`,
    /// this project's established diagnostic technique for exactly this
    /// class of question) mid-investigation: an isolated run of just this
    /// swipe (skipping the previous phase) applied cleanly every time,
    /// while running both phases back to back against the same message
    /// reproducibly left it unread server-side — the swipe's own op queued
    /// and replayed correctly, it just replayed *second*.
    func testMarkReadWhileOfflineAppliesLocally() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app))

        let subject = "HTML版だより"
        XCTAssertTrue(waitForSeededSubjectScrollingIfNeeded(subject, in: app))
        let list = app.collectionViews["messageList.list"]
        let row = list.cells.containing(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
        row.swipeRight()

        let toggleReadButton = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "toggleRead")).firstMatch
        XCTAssertTrue(toggleReadButton.waitForExistence(timeout: 10), "Expected the leading swipe action to reveal while offline")
        toggleReadButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        XCTAssertTrue(toggleReadButton.waitForNonExistence(timeout: 10), "Expected the swipe action to dismiss after tapping, even offline")

        // The swipe action collapsing is a *UI* signal only — SwiftUI
        // dismisses `.swipeActions` synchronously as soon as the button's
        // action closure starts running, independent of whether
        // `MessageListView.toggleRead`'s own `Task { ... }` (the actual
        // GRDB write + opQueue enqueue) has finished. An earlier version of
        // this test ended right here and the wrapping script's later
        // `doveadm` check (after coming back online) found the message
        // still unread server-side — not because replay itself failed, but
        // because the *local* write/enqueue had never actually run before
        // this test process's app got torn down for the next phase. Delete
        // (below) doesn't have this gap because it waits on a real
        // completion signal (`row.waitForNonExistence`, which only resolves
        // once the DB write lands and the list's `ValueObservation`
        // re-renders); toggling read has no equivalent visible signal (the
        // unread dot is `.accessibilityHidden`), so a fixed wait is the
        // next best thing.
        Thread.sleep(forTimeInterval: 3)
    }

    /// Phase: mailstack still down. Deletes the no-subject seed message
    /// (`17-no-subject.eml`) via a trailing swipe while offline — the
    /// local optimistic removal (`MessageListView.deleteThread`) must not
    /// require any network reachability.
    func testDeleteWhileOfflineRemovesRowLocally() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app))

        let subject = "(件名なし)"
        XCTAssertTrue(waitForSeededSubjectScrollingIfNeeded(subject, in: app))
        let list = app.collectionViews["messageList.list"]
        let row = list.cells.containing(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
        row.swipeLeft()

        let deleteButton = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "delete")).firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 10), "Expected the trailing swipe action to reveal 削除 while offline")
        deleteButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        XCTAssertTrue(
            row.waitForNonExistence(timeout: 10),
            "Expected the deleted message to disappear locally immediately, even with no network"
        )
    }

    /// Phase: mailstack back up. A plain cold relaunch is enough to trigger
    /// `RootView`'s scenePhase==.active opQueue replay (same mechanism
    /// M3/M5's own scripts rely on) — this just confirms the app survives
    /// that transition cleanly and reaches a normal, populated state; the
    /// wrapping shell script separately confirms via `doveadm` that the
    /// \Seen flag and the Trash move actually reached the server.
    func testRelaunchAfterMailstackComesBackUpReplaysCleanly() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "Expected the message list reachable after the mailstack came back and opQueue replay ran")
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.cells.firstMatch.waitForExistence(timeout: 20), "Expected a populated list after replay, not stuck empty")
    }

    /// Phase: mailstack taken back down again *immediately* after the
    /// previous phase's online replay — "up 後の replay 中に再度 down" from
    /// the task's scenario list, approximated as tightly as XCUITest/host-
    /// shell orchestration allows (a truly mid-replay disconnect isn't
    /// controllable from here — see the M3 verification's own note on why
    /// a live IDLE/replay race can't be driven deterministically from
    /// XCUITest). Confirms the app tolerates going offline again right
    /// after coming online without getting stuck or corrupting the list.
    func testColdLaunchAfterGoingOfflineAgainStillWorks() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "Expected the message list reachable after going offline again right after a replay")
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.cells.firstMatch.waitForExistence(timeout: 20), "Expected the list to remain populated (not emptied) after another offline transition")
    }
}
