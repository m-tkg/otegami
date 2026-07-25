import XCTest

/// M7: shared steps for driving a `.searchable` search bar — originally
/// `MessageListView`'s own (M7), now iOS's dedicated `SearchTabView`
/// (design-phase-2: 1a moved search to its own tab; macOS still searches
/// in place on `MessageListView`, unchanged). On iOS, `.searchable` renders
/// as a system search field — `app.searchFields`, a distinct
/// `XCUIElementTypeSearchField`, not `app.textFields`. Located via
/// `.firstMatch` rather than a custom `accessibilityIdentifier`: chaining
/// `.accessibilityIdentifier` after `.searchable(...)` doesn't tag the
/// search field itself, it *replaces* whatever identifier the `List` it's
/// attached to already had (see `MessageListView`'s doc comment on that
/// modifier chain, still true for `SearchTabView`) — `.searchable` only
/// ever produces one search bar per screen, so `.firstMatch` is
/// unambiguous without needing an identifier at all.
extension XCTestCase {
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
}
