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
///
/// D8 「しきい値で自動実行」バッチ: both methods used to reveal a swipe-
/// action button (`.swipeActions`) and tap it. `MessageListRow` now fires
/// the default leading-short (既読/未読切替) / trailing-short (削除) action
/// directly once the drag crosses `shortSwipeThreshold` and the finger
/// lifts — no button anymore, so both methods drag past that threshold with
/// `performThresholdSwipe(on:distancePoints:in:)` and assert the resulting
/// effect directly instead of finding-then-tapping a revealed button. See
/// `OtegamiSwipeAutoFireUITests` for a dedicated short-vs-long-threshold and
/// sub-threshold-no-op regression suite.
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
        // Design-phase-2: 1a's bottom tab bar (`OtegamiRootView`) didn't
        // exist when this test was first written and shrinks the message
        // list's usable viewport height versus before — this seeded row
        // (older, so it sorts low in the newest-first list) now lands close
        // enough to that closer bottom edge that `swipeRight()` doesn't
        // reliably reveal the leading swipe action there, the same "row too
        // close to a viewport edge" issue `testSwipeDeletesMessageOffline`
        // (below) already had to nudge around for a different row — see its
        // doc comment for the full diagnosis. One extra scroll step, using
        // the same drag `waitForElementScrollingIfNeeded` uses, brings it
        // clear before swiping; re-queried after scrolling since a scroll
        // can invalidate the previous element reference.
        let list = app.collectionViews["messageList.list"]
        _ = row(forSubject: "Ｆｗｄ：今月のリリースノート", in: app) // exists-check only; re-queried below post-scroll
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        start.press(forDuration: 0.05, thenDragTo: end)
        let row = row(forSubject: "Ｆｗｄ：今月のリリースノート", in: app)

        // Leading drag (positive `distancePoints`, past `shortSwipeThreshold`
        // but short of `longSwipeThreshold`) fires the leading-short action
        // — 既読/未読切替 by default — the instant the finger lifts. There is
        // no button to find/tap anymore; the row stays put (toggling read
        // state doesn't remove it from the list), so this method only
        // confirms the row survives the swipe and the list stays responsive
        // — the actual server-side `\Seen` effect is confirmed afterward by
        // `scripts/verify-ios-m3.sh`'s host-side `doveadm fetch` poll.
        performThresholdSwipe(on: row, distancePoints: 100, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "既読/未読切替 should leave the row in place, just with its flag flipped")
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
        // Trailing drag (negative `distancePoints`, past `shortSwipeThreshold`)
        // fires the trailing-short action — 削除 by default — immediately on
        // release. No button to reveal/tap anymore (previously this test
        // guarded delete behind a tap-only reveal via
        // `SwipeAction.isGuardedFromFullSwipe`; that guard is gone — see
        // `MessageListRow`'s doc comment — delete/迷惑メール now auto-fire
        // like every other action, with the existing undo toast as the
        // safety net).
        performThresholdSwipe(on: row, distancePoints: -100, in: app)

        XCTAssertTrue(
            row.waitForNonExistence(timeout: 10),
            "Expected the deleted message to disappear from the list immediately (local optimistic removal, opQueue delete enqueued for replay once back online)"
        )
    }

    // MARK: - Steps

    private func row(forSubject subject: String, in app: XCUIApplication) -> XCUIElement {
        let list = app.collectionViews["messageList.list"]
        let row = list.cells.containing(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
        // QA sweep: `dev/mailstack/seed/fixtures/` grew again (17/18, both
        // sorting ahead of this older fixture) — same "row pushed off the
        // initial screen" regression M10 already documented and fixed
        // elsewhere via this scrolling helper; this call site had been
        // missed until a QA-sweep regression pass caught it.
        XCTAssertTrue(waitForElementScrollingIfNeeded(row, in: app), "Expected message \"\(subject)\" to be in the list")
        return row
    }
}
