import XCTest

/// Shared steps for driving `SearchScreenView`'s search field — opened as a
/// sheet from `MailScreenView`'s header search button (macOS still searches
/// in place on `MessageListView`'s own `.searchable`, unchanged).
///
/// **検索画面再構成 (Task #86)**: `SearchScreenView`'s top bar
/// (`SearchTopBar`) replaced the system `.searchable` search bar with a
/// plain `TextField` (so it could carry a leading "save this query" star
/// inside the same rounded field) — the field is now `app.textFields`
/// tagged with a real `accessibilityIdentifier` (`search.textField`), not
/// `app.searchFields` (`XCUIElementTypeSearchField`) located by
/// `.firstMatch`. There's also no more system "Clear text" (x) button or
/// keyboard "Cancel" affordance — `clearSearchQuery(in:)` below deletes by
/// sending backspace keys instead.
extension XCTestCase {
    /// 検索画面再構成: opens `SearchScreenView` via `MailScreenView`'s header
    /// search button (`mail.searchButton`) and waits for its search field to
    /// be reachable. Every test that used to rely on being able to reach the
    /// 検索タブ directly should call this first.
    @discardableResult
    func openSearchScreen(in app: XCUIApplication) -> Bool {
        let searchButton = app.buttons["mail.searchButton"]
        guard searchButton.waitForExistence(timeout: 10) else { return false }
        searchButton.tap()
        return app.textFields["search.textField"].waitForExistence(timeout: 10)
    }

    func typeSearchQuery(_ query: String, in app: XCUIApplication) {
        let searchField = app.textFields["search.textField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "Search field did not appear")
        searchField.tap()
        searchField.typeText(query)
    }

    /// Deletes whatever text is currently in the search field via backspace
    /// keys — there's no system "Clear text" button on this plain
    /// `TextField` (see this file's doc comment). A no-op if the field is
    /// already empty.
    func clearSearchQuery(in app: XCUIApplication) {
        let searchField = app.textFields["search.textField"]
        guard searchField.exists, let value = searchField.value as? String, !value.isEmpty else { return }
        searchField.tap()
        searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
    }

    /// 検索画面再構成: closes `SearchScreenView`'s sheet (`search.closeButton`
    /// — now the rounded X button at the top bar's trailing edge, same
    /// identifier as the old `.toolbar` cancellation button it replaced).
    @discardableResult
    func closeSearchScreen(in app: XCUIApplication) -> Bool {
        let closeButton = app.buttons["search.closeButton"]
        guard closeButton.waitForExistence(timeout: 5) else { return false }
        closeButton.tap()
        return true
    }
}
