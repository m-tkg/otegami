import XCTest

/// M3 verification, phases 3/4 ("フラグ同期" / "オフライン操作キュー"): swipe
/// actions on `MessageListView` rows. Both test methods assume the account
/// from `OtegamiM3SetupUITests` is already persisted (Keychain + GRDB
/// survive a relaunch); `scripts/verify-ios-m3.sh` runs
/// `testSwipeMarksMessageRead` while the mailstack is up (so the opQueue's
/// best-effort immediate replay actually reaches the server — verified via
/// `doveadm fetch` from the host afterward) and `testSwipeDeletesMessageOffline`
/// while it's stopped (so only the local optimistic removal + enqueue can
/// be confirmed here; the replay-once-back-online part is verified by the
/// script after `make mailstack-up`, again via `doveadm`).
final class OtegamiM3SwipeActionsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSwipeMarksMessageRead() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        // Not "明日の打ち合わせについて" — that subject is also a substring
        // of the seeded reply "Re: 明日の打ち合わせについて", which sorts
        // ahead of it (newer) and so wins `.containing(predicate)
        // .firstMatch`; that reply also happens to have already been
        // opened (and thus marked \Seen) by earlier M1/M2 verification
        // runs sharing this same simulator install, which flips the
        // revealed action's label to "未読にする" instead of "既読にする"
        // — a real ambiguous-predicate bug caught via a debug screenshot
        // taken mid-swipe, not an environment quirk. This subject has no
        // such collision.
        let row = row(forSubject: "Ｆｗｄ：今月のリリースノート", in: app)

        // Leading swipe (`XCUIElement.swipeRight()`) reveals the
        // toggle-read action (`.swipeActions(edge: .leading)` in
        // `MessageListView`) — matched by its accessibility identifier
        // suffix rather than its label text, since the label reads
        // "既読にする"/"未読にする" depending on the message's *current*
        // flag state, which this test doesn't want to assume.
        row.swipeRight()

        let toggleReadButton = swipeActionButton(identifierSuffix: "toggleRead", in: app)
        XCTAssertTrue(toggleReadButton.waitForExistence(timeout: 10), "Expected the leading swipe action button to appear")
        toggleReadButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        XCTAssertTrue(toggleReadButton.waitForNonExistence(timeout: 10), "Swipe action should dismiss once tapped")
    }

    func testSwipeDeletesMessageOffline() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        let subject = "M3差分同期テスト"

        // M10: `08-m3-new-mail.eml`'s own `Date:` header (Jan 7, 2026) is
        // now old enough, relative to the fixture set that grew across
        // M2-M8, that this row sits right at the *bottom edge* of the
        // list's viewport rather than comfortably on screen — confirmed
        // via `app.debugDescription` (its frame ended 4.7pt short of the
        // CollectionView's own bottom bound). A `swipeLeft()` starting
        // that close to the edge doesn't reliably reveal the swipe
        // action (plausibly clipped by, or too close to, whatever system
        // chrome/the search pill sits at the very bottom). One scroll
        // down first — using the same drag helper `waitForElementScrollingIfNeeded`
        // uses — brings it clear of the edge; the row was already
        // confirmed to exist without any scroll, so this isn't the
        // "row isn't mounted yet" case that helper handles, just "row
        // exists but is positioned somewhere `swipeLeft()` can't act on."
        let list = app.collectionViews["messageList.list"]
        _ = row(forSubject: subject, in: app) // exists-check only; re-queried below post-scroll since a scroll can invalidate element references
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        start.press(forDuration: 0.05, thenDragTo: end)

        let row = row(forSubject: subject, in: app)
        // Trailing swipe (`XCUIElement.swipeLeft()`) reveals "削除"
        // (`.swipeActions(edge: .trailing)` in `MessageListView`).
        row.swipeLeft()

        let deleteButton = swipeActionButton(identifierSuffix: "delete", in: app)
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 10), "Expected the trailing swipe action to reveal \"削除\"")
        deleteButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        XCTAssertTrue(
            row.waitForNonExistence(timeout: 10),
            "Expected the deleted message to disappear from the list immediately (local optimistic removal, opQueue delete enqueued for replay once back online)"
        )
    }

    // MARK: - Steps

    private func row(forSubject subject: String, in app: XCUIApplication) -> XCUIElement {
        let list = app.collectionViews["messageList.list"]
        let row = list.cells.containing(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Expected message \"\(subject)\" to be in the list")
        return row
    }

    /// `app.buttons["messageList.row.<id>.\(identifierSuffix)"]` (exact
    /// identifier lookup) is the kind of query this project's simulator/
    /// toolchain has previously failed to match even for a visible element
    /// (see `.claude/skills/verify/SKILL.md`) — a `CONTAINS` predicate
    /// against `identifier` finds it reliably instead, the same technique
    /// already used for label text elsewhere in this suite.
    private func swipeActionButton(identifierSuffix: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", identifierSuffix)).firstMatch
    }
}
