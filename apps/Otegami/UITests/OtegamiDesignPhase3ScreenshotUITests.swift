import XCTest

/// design-phase-3 verification (task 4): holds each of 1j (検索)/1l (設定)/
/// 1k (作成) up on screen long enough for the wrapping shell command's
/// concurrent host-side `xcrun simctl io screenshot` (and, for
/// light/dark, `xcrun simctl ui ... appearance`) calls to land inside the
/// window — the same "screenshot mid-test, not after" technique M6/M7/M8
/// established for non-`@AppStorage`-persisted screens (`docs/verify.md`).
/// Builds on top of whatever account/seed state earlier phases already
/// established in this simulator install.
final class OtegamiDesignPhase3ScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHoldSearchSettingsAndComposerForScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 30))

        // Phase 1: 検索画面 (1j), opened as a sheet from the header search
        // button (新画面構成 — no tab bar anymore), with a query active
        // (filter chips + results visible).
        openSearchScreen(in: app)
        XCTAssertTrue(app.collectionViews["search.list"].waitForExistence(timeout: 15))
        typeSearchQuery("ようこそ", in: app)
        Thread.sleep(forTimeInterval: 3)
        // Dismiss the keyboard (submit via Return) before closing the
        // sheet — the keyboard fully covers the close button while up.
        app.searchFields.firstMatch.typeText("\n")
        Thread.sleep(forTimeInterval: 3)
        closeSearchScreen(in: app)

        // Phase 2: 設定 (1l), opened via the hamburger menu's bottom row —
        // アカウント/操作/翻訳 sections. Label text, not the exact
        // `navigationBars` subscript — this simulator/toolchain's
        // well-documented exact-identifier-lookup pitfall applies to
        // navigation bar titles too (`docs/verify.md`).
        openSettingsFromHamburgerMenu(in: app)
        let addAccountButton = app.buttons["settings.addAccountButton"]
        XCTAssertTrue(addAccountButton.waitForExistence(timeout: 15))
        // 操作/翻訳 (1l's new sections) sit below アカウント/iCloud/プッシュ通知
        // — scroll down so both are actually in frame for the screenshot,
        // not just the account list at the top.
        app.swipeUp()
        Thread.sleep(forTimeInterval: 6)
        closeSettingsSheet(in: app)

        // Phase 3: Composer (1k), reached via the header toolbar's "作成"
        // button — 差出人 always visible at the top, 翻訳 section near the
        // bottom.
        let composeButton = app.buttons["mail.composeButton"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 15))
        composeButton.tap()
        let composerSheet = app.otherElements["composer.sheet"]
        XCTAssertTrue(composerSheet.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 6)
    }
}
