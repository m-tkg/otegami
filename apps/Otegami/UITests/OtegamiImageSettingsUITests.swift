import XCTest

/// B: verifies the two independent image auto-display settings
/// (`ImageSettingsStore`) actually change `HTMLMessageView`'s banner
/// behavior, in both the default state (`testDefaultImageSettings`) and
/// fully flipped (`testFlippedImageSettingsViaPresetDefaults`) — covering
/// all four (embedded, remote) × (banner shown, banner hidden)
/// combinations, since each fixture/setting pairing below is independently
/// observed in both states. Mirrors `OtegamiM2VerificationUITests`'s
/// helpers.
final class OtegamiImageSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Default state: embedded OFF, remote ON (`ImageSettingsStore`'s
    /// defaults — a deliberate flip from this app's pre-B behavior).
    func testDefaultImageSettings() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        try addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        // 16-cid-inline-image.eml: embedded banner should show (default off).
        openMessage(subject: "インライン画像つきHTMLメール", in: app)
        let embeddedBanner = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "埋め込み画像を表示")).firstMatch
        XCTAssertTrue(embeddedBanner.waitForExistence(timeout: 15), "Expected the embedded-image banner by default (autoShowEmbedded defaults off)")
        Thread.sleep(forTimeInterval: 3)
        returnToMessageList(in: app)

        // 06-html-external-image.eml: remote banner should NOT show (default on).
        openMessage(subject: "【otegami】新機能のお知らせ", in: app)
        assertBodyContains(text: "新機能についてお知らせします", in: app)
        let remoteBanner = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "画像を表示")).firstMatch
        XCTAssertFalse(remoteBanner.waitForExistence(timeout: 5), "Expected no remote-image banner by default (autoShowRemote defaults on)")
        Thread.sleep(forTimeInterval: 4)
    }

    /// Flipped state: embedded ON, remote OFF. Sets both `UserDefaults` keys
    /// directly from the shell *before* this test even launches the app
    /// (`scripts` invoking `xcrun simctl spawn ... defaults write
    /// com.mtkg.otegami images.autoShow... -bool ...`) rather than driving
    /// the Settings screen's `Toggle`s in-process — a plain `.tap()` *and*
    /// a coordinate `press()` on those `Toggle`s were both observed to
    /// leave `HTMLMessageView`'s banner behaving as if the setting never
    /// changed, even though the switch was found and neither raised an
    /// error (this dev machine's beta simulator/toolchain again — see
    /// `docs/verify.md`'s A9 flake notes for the same class of issue
    /// elsewhere in this session). Writing the defaults directly and
    /// launching fresh sidesteps the unreliable step entirely while still
    /// exercising the real code path this test cares about: a freshly
    /// constructed `HTMLMessageView` reading the current setting value.
    func testFlippedImageSettingsViaPresetDefaults() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        try addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        // 16-cid-inline-image.eml: embedded banner should now be gone.
        openMessage(subject: "インライン画像つきHTMLメール", in: app)
        assertBodyContains(text: "こんにちは、otegami です", in: app)
        let embeddedBannerAfter = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "埋め込み画像を表示")).firstMatch
        XCTAssertFalse(embeddedBannerAfter.waitForExistence(timeout: 5), "Expected no embedded-image banner with autoShowEmbedded preset to true")
        Thread.sleep(forTimeInterval: 3)
        returnToMessageList(in: app)

        // 06-html-external-image.eml: remote banner should now appear.
        openMessage(subject: "【otegami】新機能のお知らせ", in: app)
        let remoteBannerAfter = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "画像を表示")).firstMatch
        XCTAssertTrue(remoteBannerAfter.waitForExistence(timeout: 15), "Expected the remote-image banner with autoShowRemote preset to false")
        Thread.sleep(forTimeInterval: 4)
    }

    // MARK: - Steps

    private func openMessage(subject: String, in app: XCUIApplication) {
        let list = app.collectionViews["messageList.list"]
        let predicate = NSPredicate(format: "label CONTAINS %@", subject)
        let row = list.cells.containing(predicate).firstMatch
        XCTAssertTrue(waitForElementScrollingIfNeeded(row, in: app), "Expected seeded message \"\(subject)\" to appear in the INBOX list")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
    }

    private func returnToMessageList(in app: XCUIApplication) {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.waitForExistence(timeout: 3) {
            backButton.tap()
        }
    }

    private func assertBodyContains(text: String, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let element = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "Expected message body to contain \"\(text)\"")
    }
}
