import XCTest

/// M7 verification, phase 2: five independent search scenarios against the
/// accounts `OtegamiM7SetupUITests` already added, matching the plan's
/// checkpoints (a)-(e). Each scenario is its own `XCTestCase` method run in
/// its own `xcodebuild test -only-testing:` invocation (`scripts
/// /verify-ios-m7.sh`) — a fresh `app.launch()` per method, reusing the
/// GRDB state `OtegamiM7SetupUITests` persisted. Search results are pure
/// `@State`, not `@AppStorage`-backed, so (unlike M1-M5's message list)
/// there's nothing to see if a screenshot is taken *after* the test process
/// exits; every method instead holds its result screen up with
/// `Thread.sleep` right before returning, the same "screenshot mid-test
/// from a concurrently-running host shell" technique M6 established for
/// its own non-persisted account-setup sheets (`docs/verify.md`'s M6
/// section).
///
/// Design-phase-2 moved search off `MessageListView`'s own `.searchable`
/// bar and into a dedicated search tab; 新画面構成 replaced that tab
/// with `SearchScreenView`, opened as a sheet from `MailScreenView`'s
/// header search button — every assertion below still reads from
/// `search.list` rather than `messageList.list`, and each test opens the
/// search sheet before typing a query.
///
/// All five queries deliberately hit on `message.subject` alone (never
/// `messageBody.plainText`), so none of them depends on
/// `BodyFetcher.prefetchRecent`'s background body-fetch pass having
/// finished by the time the search runs — only on the envelope-time
/// `AccountSyncer.upsert`/`FTSIndexer.reindex` write, which is already
/// committed by the time `OtegamiM7SetupUITests` observes a seeded subject
/// in the message list at all.
final class OtegamiM7SearchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches, confirms the message list is reachable (the account/data
    /// baseline `OtegamiM7SetupUITests` established), then opens
    /// `SearchScreenView` (新画面構成: a header search button, no tab bar
    /// anymore) and waits for its own list to be ready.
    private func launchOnSearchTab() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 30))
        openSearchScreen(in: app)
        XCTAssertTrue(app.collectionViews["search.list"].waitForExistence(timeout: 15))
        return app
    }

    /// Scenario (a): a 2-character Japanese query ("打ち") hits via
    /// `SearchQuery`'s `LIKE` fallback — the References-threaded
    /// "明日の打ち合わせについて" / "Re: 明日の打ち合わせについて" pair
    /// (`02-thread-original.eml`/`03-thread-reply.eml`), folded into one
    /// thread row showing the newer subject.
    func testTwoCharacterJapaneseQueryHits() throws {
        let app = launchOnSearchTab()
        typeSearchQuery("打ち", in: app)

        let hit = app.collectionViews["search.list"]
            .staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "打ち合わせ")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 15), "Expected a 2-character LIKE-fallback search to find \"打ち合わせ\"")

        Thread.sleep(forTimeInterval: 7)
    }

    /// Scenario (b): the same thread, found via a 3+ character query
    /// ("打ち合わせ") that routes through the FTS5 trigram `MATCH` path
    /// instead of the `LIKE` fallback.
    func testThreeCharacterJapaneseQueryHitsViaFTS() throws {
        let app = launchOnSearchTab()
        typeSearchQuery("打ち合わせ", in: app)

        let hit = app.collectionViews["search.list"]
            .staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "打ち合わせ")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 15), "Expected a 3+ character FTS search to find \"打ち合わせ\"")

        Thread.sleep(forTimeInterval: 7)
    }

    /// Scenario (c): an English query ("html", lowercase) hits
    /// `07-html-only-japanese.eml`'s subject ("HTML版だより") — also
    /// exercises FTS5 trigram's ASCII case folding.
    func testEnglishQueryHits() throws {
        let app = launchOnSearchTab()
        typeSearchQuery("html", in: app)

        let hit = app.collectionViews["search.list"]
            .staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "HTML版だより")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 15), "Expected a lowercase \"html\" query to case-insensitively match \"HTML版だより\"")

        Thread.sleep(forTimeInterval: 7)
    }

    /// Scenario (d): `SearchScreenView` always searches across every account
    /// (design-phase-2: it has no per-mailbox scope picker at all — see its
    /// doc comment), so a query ("ようこそ", present in both accounts'
    /// welcome-message subjects) returns results from *both* test1 and
    /// test2 unconditionally.
    func testUnifiedScopeReturnsBothAccounts() throws {
        let app = launchOnSearchTab()
        typeSearchQuery("ようこそ", in: app)

        let list = app.collectionViews["search.list"]
        let test1Hit = list.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ようこそ otegami へ")).firstMatch
        let test2Hit = list.staticTexts["test2 アカウントへようこそ"]
        XCTAssertTrue(test1Hit.waitForExistence(timeout: 15), "Expected test1's welcome message in the cross-account search results")
        XCTAssertTrue(test2Hit.waitForExistence(timeout: 15), "Expected test2's welcome message in the cross-account search results")

        Thread.sleep(forTimeInterval: 7)
    }

    /// Scenario (e): a query with no possible local match shows the
    /// 「サーバーで検索」トリガー行 (`ServerSearchTriggerRow`,
    /// `search.serverSearch.trigger`) rather than an empty-looking list
    /// with no explanation. This replaced the plain `ContentUnavailableView
    /// .search`/`search.emptyState` overlay when 検索の IMAP サーバーサイド
    /// SEARCH フォールバック shipped — that overlay would otherwise sit on
    /// top of (and block taps on) the trigger row `resultsSections` now
    /// always renders at the end of the local results, zero local hits or
    /// not.
    func testNoMatchesShowsServerSearchTrigger() throws {
        let app = launchOnSearchTab()
        typeSearchQuery("zzzznotfound", in: app)

        let trigger = app.buttons["search.serverSearch.trigger"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 15), "Expected the サーバーで検索 trigger row to appear even with zero local hits")

        // The search list should have exactly the trigger row in it — no
        // local result rows for this query.
        XCTAssertEqual(app.collectionViews["search.list"].cells.count, 1, "Expected zero result rows plus the server-search trigger row")

        Thread.sleep(forTimeInterval: 7)
    }
}
