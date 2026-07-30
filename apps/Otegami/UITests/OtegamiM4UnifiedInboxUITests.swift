import XCTest

/// M4 verification, phase 4 (plan checkpoint (c): "test2 アカウントを追加 →
/// 統合受信トレイに両アカウントのスレッドが日付順で混在"). Adds the dev mailstack's
/// second seeded account on top of whatever `OtegamiM4SetupUITests` already
/// established, then confirms the sidebar's default "すべての受信トレイ"
/// selection (M4: `SidebarView` auto-selects it on first launch) lists
/// threads from *both* accounts together.
final class OtegamiM4UnifiedInboxUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddingSecondAccountShowsBothAccountsInUnifiedInbox() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        // A fresh launch with an existing account always starts already on
        // the Mail tab's message list (design-phase-2: no restored/
        // intermediate screen to skip past). `returnToMailTabRootIfNeeded`
        // still pops back to the Mail tab root to reach the account filter
        // chip row's "＋" entry point.
        returnToMailTabRootIfNeeded(in: app)

        try addDovecotTest2Account(in: app)
        restartAppToRecoverTouchDelivery(app)

        // No pop needed here — the restart above is itself a fresh
        // `app.launch()`, which (same reasoning) comes back up already on
        // the message list.
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        // test1's thread (survives from OtegamiM4SetupUITests).
        let test1Thread = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "来週のランチ")).firstMatch
        XCTAssertTrue(waitForElementScrollingIfNeeded(test1Thread, in: app), "Expected test1's thread to still appear in the unified inbox")

        // test2's own single seeded message (05-test2-welcome.eml). M10:
        // `waitForSeededSubjectScrollingIfNeeded` — see its doc comment
        // (dev/mailstack's seed fixture set grew enough across M2-M8 that
        // this doesn't necessarily fit on the first screen anymore either).
        XCTAssertTrue(
            waitForSeededSubjectScrollingIfNeeded("test2 アカウントへようこそ", in: app),
            "Expected test2's seeded message to appear in the unified inbox"
        )
    }
}
