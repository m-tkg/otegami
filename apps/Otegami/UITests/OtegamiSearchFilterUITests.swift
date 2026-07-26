import XCTest

/// design-phase-3 verification (1j): the filter chip row (全部/添付/未読/英語
/// — `SearchFilterOption`) and 人/メール sectioning added on top of M7's
/// search baseline. Builds on whatever account/seed state earlier phases
/// (M7, the translation UITests) already established in this simulator
/// install — same "each phase its own `-only-testing:` invocation" pattern
/// as the rest of this suite (`docs/verify.md`).
final class OtegamiSearchFilterUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchOnSearchTab() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 30))
        app.tabBars.buttons["検索"].tap()
        XCTAssertTrue(app.collectionViews["search.list"].waitForExistence(timeout: 15))
        return app
    }

    /// A query matching the English seed fixture's sender name ("Aiko
    /// Tanaka") should land the result under the "人" section header.
    func testSenderNameMatchAppearsUnderPeopleSection() throws {
        let app = launchOnSearchTab()
        typeSearchQuery("Aiko", in: app)

        let peopleHeader = app.staticTexts.matching(NSPredicate(format: "label == %@", "人")).firstMatch
        XCTAssertTrue(peopleHeader.waitForExistence(timeout: 15), "Expected a sender-name match to produce a \"人\" section header")

        let hit = app.collectionViews["search.list"]
            .staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Quarterly report")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 15), "Expected Aiko Tanaka's message to appear in the results")

        Thread.sleep(forTimeInterval: 3)
    }

    /// The "英語" chip should narrow a query that only matches Japanese
    /// seed messages down to an empty-results state.
    func testEnglishFilterChipExcludesJapaneseOnlyMatches() throws {
        let app = launchOnSearchTab()
        typeSearchQuery("ようこそ", in: app)

        let hit = app.collectionViews["search.list"]
            .staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ようこそ")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 15), "Expected the unfiltered ようこそ query to find seeded Japanese welcome messages")

        let englishChip = app.buttons["search.filterChip.english"]
        XCTAssertTrue(englishChip.waitForExistence(timeout: 10), "Expected the 英語 filter chip to be present once results are showing")
        englishChip.tap()

        let emptyState = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No Results")).firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10), "Expected the 英語 chip to filter out every Japanese-only ようこそ match")

        Thread.sleep(forTimeInterval: 3)
    }
}
