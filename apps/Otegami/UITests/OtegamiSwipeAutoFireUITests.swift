import XCTest

/// D8 「しきい値で自動実行」バッチ: `MessageListRow`'s iOS swipe UI moved off
/// SwiftUI's button-reveal `.swipeActions` onto a custom `DragGesture` that
/// fires the action the instant the finger lifts past a threshold — no
/// button, nothing to tap (see that type's doc comment for the full design
/// writeup, and `docs/design-system.md`'s dedicated section for the
/// threshold values/gesture-vs-scroll approach). This suite is the
/// dedicated regression check for the mechanism itself: a drag short of the
/// short threshold fires nothing (row springs back), a drag past the short
/// threshold but short of the long one fires the *short* action, and a drag
/// past the long threshold fires the *long* action — all without any
/// intermediate "tap to confirm" step.
///
/// Reassigns the trailing edge to ピン留め (short) / アーカイブ (long) — two
/// actions with cleanly UI-observable, and *different*, effects (a pin
/// indicator appearing vs. the row leaving the list entirely) — rather than
/// the trailing defaults (削除/削除 for both slots), which wouldn't let a
/// single suite distinguish "the short threshold fired" from "the long
/// threshold fired" by outcome alone. Both are also non-destructive to the
/// shared dev mailstack in the way `testSwipeDeletesMessageOffline` isn't:
/// pinning is a purely local, reversible flag, and archiving (an IMAP MOVE
/// to the account's Archive mailbox) is fully undone by the next
/// `make mailstack-seed`, which re-`doveadm save`s every fixture straight
/// into INBOX regardless of what's sitting in Archive — the same reasoning
/// `docs/verify.md`'s "dev/mailstack: state persists across milestones"
/// note already documents for other swipe/delete UITests in this app.
final class OtegamiSwipeAutoFireUITests: XCTestCase {
    /// The seeded subject this suite targets (`20-english-quarterly-report.eml`)
    /// — not otherwise referenced by any other swipe/pin/archive UITest in
    /// this target, to avoid two suites fighting over the same row's state
    /// within one simulator install.
    private let targetSubject = "Quarterly report and next steps"

    /// `MessageListRow.shortSwipeThreshold`/`.longSwipeThreshold` are
    /// `private let`s (72pt / 152pt as of this writing) — duplicated here as
    /// plain distances comfortably on either side of each threshold, since a
    /// UITest target can't import the app's internal declarations. Keep
    /// these in sync if those thresholds ever move.
    private let belowShortThresholdDistance: CGFloat = 30
    private let betweenShortAndLongDistance: CGFloat = 100
    private let pastLongThresholdDistance: CGFloat = 200

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// No-op if an account already exists (`mail.addAccountButton` only
    /// shows in the zero-account empty state) — same pattern
    /// `OtegamiPinSwipeListDisplayUITests` already established, so every
    /// test method here can call this unconditionally regardless of which
    /// order XCTest happens to run them in.
    private func ensureDovecotTest1AccountExists(in app: XCUIApplication) {
        guard app.buttons["mail.addAccountButton"].waitForExistence(timeout: 5) else { return }
        let emptyStateButton = app.buttons["mail.addAccountButton"]
        emptyStateButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        let otherButton = app.buttons["accountTypeSelection.otherButton"]
        XCTAssertTrue(otherButton.waitForExistence(timeout: 10), "Account type selection sheet did not appear")
        otherButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        XCTAssertTrue(app.textFields["accountSetup.displayName"].waitForExistence(timeout: 5), "Account setup sheet did not appear")
        fillDovecotAccountForm(in: app)
        runConnectionTest(in: app)
        saveAccount(in: app)
        dismissSavePasswordPromptIfNeeded()
    }

    func testDragBelowShortThresholdFiresNothing() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()
        ensureDovecotTest1AccountExists(in: app)
        restartAppToRecoverTouchDelivery(app)
        assignTrailingSwipeSlots(in: app)

        let row = targetRow(in: app)
        performThresholdSwipe(on: row, distancePoints: -belowShortThresholdDistance, in: app)

        // Neither action should have fired: the row is still present (not
        // archived away) and unpinned (no pin indicator, and it hasn't
        // jumped to the very top of the newest-first list).
        XCTAssertTrue(row.waitForExistence(timeout: 5), "A sub-threshold drag should not archive the row")
        XCTAssertFalse(pinnedIndicatorExists(in: app), "A sub-threshold drag should not pin the row either")
    }

    func testShortSwipeFiresTheShortActionImmediately() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()
        ensureDovecotTest1AccountExists(in: app)
        restartAppToRecoverTouchDelivery(app)
        assignTrailingSwipeSlots(in: app)

        let row = targetRow(in: app)
        performThresholdSwipe(on: row, distancePoints: -betweenShortAndLongDistance, in: app)

        // ピン留め (trailing-short) fires immediately — the row stays in the
        // list (pinning doesn't remove anything) but should now carry the
        // pinned indicator.
        XCTAssertTrue(row.waitForExistence(timeout: 5), "ピン留め should leave the row in the list")
        XCTAssertTrue(
            waitFor({ self.pinnedIndicatorExists(in: app) }, timeout: 10),
            "Expected the short swipe to pin the thread immediately, with no confirmation tap"
        )

        // Clean up: unpin again (same short swipe toggles it back off) so a
        // re-run of this suite starts from the same unpinned baseline.
        performThresholdSwipe(on: targetRow(in: app), distancePoints: -betweenShortAndLongDistance, in: app)
        XCTAssertTrue(
            waitFor({ !self.pinnedIndicatorExists(in: app) }, timeout: 10),
            "Expected the second short swipe to unpin the thread again"
        )
    }

    func testLongSwipeFiresTheLongActionImmediately() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()
        ensureDovecotTest1AccountExists(in: app)
        restartAppToRecoverTouchDelivery(app)
        assignTrailingSwipeSlots(in: app)

        let row = targetRow(in: app)
        performThresholdSwipe(on: row, distancePoints: -pastLongThresholdDistance, in: app)

        // アーカイブ (trailing-long) fires immediately — the row leaves the
        // (INBOX-backed) list entirely, with no confirmation tap in between.
        XCTAssertTrue(
            row.waitForNonExistence(timeout: 10),
            "Expected the long swipe to archive (and remove) the row immediately, with no confirmation tap"
        )
    }

    // MARK: - Steps

    private func targetRow(in app: XCUIApplication) -> XCUIElement {
        let list = app.collectionViews["messageList.list"]
        let row = list.cells.containing(NSPredicate(format: "label CONTAINS %@", targetSubject)).firstMatch
        XCTAssertTrue(waitForElementScrollingIfNeeded(row, in: app), "Expected \"\(targetSubject)\" to be in the list")
        return row
    }

    private func pinnedIndicatorExists(in app: XCUIApplication) -> Bool {
        // Broad `.descendants(matching: .any)` rather than `app.images[...]`
        // — `docs/verify.md` documents this simulator/toolchain sometimes
        // failing to resolve a plainly-visible `Image`-backed element via a
        // type-specific exact-identifier query; scanning every element type
        // for a `CONTAINS` match on identifier sidesteps that.
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "pinnedIndicator"))
            .firstMatch
            .exists
    }

    /// Polls `predicate` instead of a single `.exists`/`.waitForExistence`
    /// check — `docs/verify.md`'s M2/M4/M7/M11 pitfalls repeatedly document
    /// this simulator/toolchain's accessibility tree lagging slightly behind
    /// a state change that has genuinely already happened, so a bare
    /// instantaneous read right after `performThresholdSwipe` can catch the
    /// tree mid-update.
    private func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return predicate()
    }

    /// Idempotent: reassigns trailing-short/-long to ピン留め/アーカイブ via
    /// the 「メール一覧」settings category, same picker flow
    /// `OtegamiPinSwipeListDisplayUITests.testPinningMovesThreadToTop`
    /// already established. Safe to call at the top of every test method
    /// regardless of run order or which values a previous run left behind.
    private func assignTrailingSwipeSlots(in app: XCUIApplication) {
        XCTAssertTrue(openSettingsFromHamburgerMenu(in: app), "Failed to open settings from the hamburger menu")
        XCTAssertTrue(navigateToMailListSettingsCategory(in: app), "「メール一覧」カテゴリへの遷移に失敗した")

        selectSwipeAction(pickerIdentifier: "settings.swipe.trailingShortPicker", japaneseLabel: "ピン留め", englishLabel: "Pin", in: app)
        selectSwipeAction(pickerIdentifier: "settings.swipe.trailingLongPicker", japaneseLabel: "アーカイブ", englishLabel: "Archive", in: app)

        XCTAssertTrue(closeSettingsSheet(in: app), "Failed to close the settings sheet")
    }

    private func selectSwipeAction(pickerIdentifier: String, japaneseLabel: String, englishLabel: String, in app: XCUIApplication) {
        let picker = app.buttons[pickerIdentifier]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Expected \(pickerIdentifier) to exist")
        picker.tap()

        // English-vs-Japanese label predicate — this dev machine's simulator
        // runs with an English system language, and `SwipeAction.title` is
        // localized (`OtegamiPinSwipeListDisplayUITests`'s `pinMenuItem`
        // lookup already established this same pattern).
        let item = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", japaneseLabel, englishLabel)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Expected a \(japaneseLabel)/\(englishLabel) menu item")
        item.tap()
    }
}
