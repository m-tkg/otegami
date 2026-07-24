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

    /// No method in this file (or `OtegamiM7SetupUITests`) ever opens a
    /// thread, so `RootView`'s "last opened thread" `@AppStorage`
    /// restoration never has anything to restore — a cold relaunch lands
    /// directly on the message list, same as `docs/verify.md`'s "Offline
    /// verification pattern" note ("A cold relaunch re-selects the first
    /// INBOX automatically ... no further taps are needed"). Deliberately
    /// does *not* call `returnToSidebarRootIfNeeded`/`popBackOnceIfNeeded`
    /// here: both would misfire on this screen, since the message list's
    /// own compact-width navigation bar always has a legitimate "back to
    /// sidebar" button of its own — calling either would just pop away
    /// from the very screen this helper needs to land on.
    private func launchOnUnifiedInbox() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 30))
        return app
    }

    /// Scenario (a): a 2-character Japanese query ("打ち") hits via
    /// `SearchQuery`'s `LIKE` fallback — the References-threaded
    /// "明日の打ち合わせについて" / "Re: 明日の打ち合わせについて" pair
    /// (`02-thread-original.eml`/`03-thread-reply.eml`), folded into one
    /// thread row showing the newer subject.
    func testTwoCharacterJapaneseQueryHits() throws {
        let app = launchOnUnifiedInbox()
        typeSearchQuery("打ち", in: app)

        let hit = app.collectionViews["messageList.list"]
            .staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "打ち合わせ")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 15), "Expected a 2-character LIKE-fallback search to find \"打ち合わせ\"")

        Thread.sleep(forTimeInterval: 4)
    }

    /// Scenario (b): the same thread, found via a 3+ character query
    /// ("打ち合わせ") that routes through the FTS5 trigram `MATCH` path
    /// instead of the `LIKE` fallback.
    func testThreeCharacterJapaneseQueryHitsViaFTS() throws {
        let app = launchOnUnifiedInbox()
        typeSearchQuery("打ち合わせ", in: app)

        let hit = app.collectionViews["messageList.list"]
            .staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "打ち合わせ")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 15), "Expected a 3+ character FTS search to find \"打ち合わせ\"")

        Thread.sleep(forTimeInterval: 4)
    }

    /// Scenario (c): an English query ("html", lowercase) hits
    /// `07-html-only-japanese.eml`'s subject ("HTML版だより") — also
    /// exercises FTS5 trigram's ASCII case folding.
    func testEnglishQueryHits() throws {
        let app = launchOnUnifiedInbox()
        typeSearchQuery("html", in: app)

        let hit = app.collectionViews["messageList.list"]
            .staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "HTML版だより")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 15), "Expected a lowercase \"html\" query to case-insensitively match \"HTML版だより\"")

        Thread.sleep(forTimeInterval: 4)
    }

    /// Scenario (d): with the unified inbox's default "すべて" scope, a
    /// query ("ようこそ", present in both accounts' welcome-message
    /// subjects) returns results from *both* test1 and test2.
    func testUnifiedScopeReturnsBothAccounts() throws {
        let app = launchOnUnifiedInbox()
        typeSearchQuery("ようこそ", in: app)

        let list = app.collectionViews["messageList.list"]
        let test1Hit = list.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ようこそ otegami へ")).firstMatch
        let test2Hit = list.staticTexts["test2 アカウントへようこそ"]
        XCTAssertTrue(test1Hit.waitForExistence(timeout: 15), "Expected test1's welcome message in the cross-account search results")
        XCTAssertTrue(test2Hit.waitForExistence(timeout: 15), "Expected test2's welcome message in the cross-account search results")

        Thread.sleep(forTimeInterval: 4)
    }

    /// Scenario (e): a query with no possible match shows the zero-results
    /// state (`ContentUnavailableView.search`, `messageList.search
    /// .emptyState`) rather than an empty-looking list with no explanation.
    func testNoMatchesShowsEmptyState() throws {
        let app = launchOnUnifiedInbox()
        typeSearchQuery("zzzznotfound", in: app)

        // `ContentUnavailableView.search(text:)`'s system-provided
        // description includes the query text itself (e.g. "No results for
        // \u{201c}zzzznotfound\u{201d}") — matching on that text directly is
        // more robust than an exact `accessibilityIdentifier` lookup on the
        // view's own container, which this simulator/toolchain doesn't
        // always resolve for a "plainly visible" element (the same
        // exact-identifier pitfall `docs/verify.md`'s M2/M4 sections
        // document for other controls).
        let emptyState = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "zzzznotfound")).firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 15), "Expected the zero-results empty state to appear")

        // The message list itself should have nothing in it.
        XCTAssertEqual(app.collectionViews["messageList.list"].cells.count, 0, "Expected zero result rows")

        Thread.sleep(forTimeInterval: 4)
    }
}
