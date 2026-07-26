import XCTest

/// M7: shared steps for driving a `.searchable` search bar — originally
/// `MessageListView`'s own (M7), then design-phase-2's dedicated
/// `SearchTabView` tab, now 新画面構成の `SearchScreenView`, opened as a
/// sheet from `MailScreenView`'s header search button (macOS still
/// searches in place on `MessageListView`, unchanged). On iOS, `.searchable`
/// renders as a system search field — `app.searchFields`, a distinct
/// `XCUIElementTypeSearchField`, not `app.textFields`. Located via
/// `.firstMatch` rather than a custom `accessibilityIdentifier`: chaining
/// `.accessibilityIdentifier` after `.searchable(...)` doesn't tag the
/// search field itself, it *replaces* whatever identifier the `List` it's
/// attached to already had (see `MessageListView`'s doc comment on that
/// modifier chain, still true for `SearchScreenView`) — `.searchable` only
/// ever produces one search bar per screen, so `.firstMatch` is
/// unambiguous without needing an identifier at all.
extension XCTestCase {
    /// 新画面構成: opens `SearchScreenView` via `MailScreenView`'s header
    /// search button (`mail.searchButton`) and waits for its search field to
    /// be reachable. Every test that used to rely on being able to reach the
    /// 検索タブ directly should call this first.
    @discardableResult
    func openSearchScreen(in app: XCUIApplication) -> Bool {
        let searchButton = app.buttons["mail.searchButton"]
        guard searchButton.waitForExistence(timeout: 10) else { return false }
        searchButton.tap()
        return app.searchFields.firstMatch.waitForExistence(timeout: 10)
    }

    func typeSearchQuery(_ query: String, in app: XCUIApplication) {
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "Search field did not appear")
        searchField.tap()
        searchField.typeText(query)
    }

    /// Taps the search bar's system "Clear text" button (shown automatically
    /// once it has text) rather than sending delete keys — a `UISearchBar`/
    /// `UISearchTextField` doesn't reliably accept `.typeText(delete...)`
    /// the way a plain `TextField` does in this simulator/toolchain (the
    /// same category of tap-delivery quirk `docs/verify.md`'s M2/M3
    /// sections document for other controls). A no-op if the field is
    /// already empty.
    func clearSearchQuery(in app: XCUIApplication) {
        let searchField = app.searchFields.firstMatch
        guard searchField.exists, let value = searchField.value as? String, !value.isEmpty else { return }
        let clearButton = searchField.buttons["Clear text"]
        if clearButton.waitForExistence(timeout: 3) {
            clearButton.tap()
        }
    }

    /// 新画面構成: closes `SearchScreenView`'s sheet (`search.closeButton`).
    @discardableResult
    func closeSearchScreen(in app: XCUIApplication) -> Bool {
        let closeButton = app.buttons["search.closeButton"]
        guard closeButton.waitForExistence(timeout: 5) else { return false }
        closeButton.tap()
        return true
    }
}
