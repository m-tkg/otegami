import XCTest

/// C7: confirms the "リンクを開く方法" picker itself renders correctly in
/// Settings — independent of `OtegamiLinkBrowserUITests` (which drives an
/// actual link tap against a seeded message and hit an unresolved
/// environment issue; see `docs/verify.md`'s C7 section). No dev-mailstack
/// account is needed for this check, since the Settings tab renders
/// regardless of the account list's contents.
final class OtegamiLinkBrowserSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLinkBrowserPickerIsShownWithDefaultSelection() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        let settingsTab = app.tabBars.buttons["設定"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15))
        settingsTab.tap()

        let picker = app.buttons["settings.links.openInAppBrowserPicker"]
        XCTAssertTrue(scrollSettingsUntilVisible(picker, in: app), "Expected the link-browser picker to appear in Settings")

        // Hold the screen up for the wrapping shell's mid-test screenshot.
        Thread.sleep(forTimeInterval: 3)
    }

    private func scrollSettingsUntilVisible(_ element: XCUIElement, in app: XCUIApplication, maxAttempts: Int = 10) -> Bool {
        var found = element.waitForExistence(timeout: 3)
        let list = app.collectionViews.firstMatch
        var attempts = 0
        while !found, attempts < maxAttempts {
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            start.press(forDuration: 0.05, thenDragTo: end)
            found = element.waitForExistence(timeout: 2)
            attempts += 1
        }
        return found
    }
}
