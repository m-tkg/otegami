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
        app.launch()

        addDovecotTest2Account(in: app)
        restartAppToRecoverTouchDelivery(app)

        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        // test1's thread (survives from OtegamiM4SetupUITests).
        let test1Thread = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "来週のランチ")).firstMatch
        XCTAssertTrue(test1Thread.waitForExistence(timeout: 20), "Expected test1's thread to still appear in the unified inbox")

        // test2's own single seeded message (05-test2-welcome.eml).
        let test2Message = app.staticTexts["test2 アカウントへようこそ"]
        XCTAssertTrue(test2Message.waitForExistence(timeout: 20), "Expected test2's seeded message to appear in the unified inbox")
    }
}
