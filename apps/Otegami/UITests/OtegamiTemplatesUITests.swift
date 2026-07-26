import XCTest

/// C8: adds a global (all-accounts) template in Settings, then confirms
/// it's offered — and correctly fills a blank Composer's subject and body
/// — from a fresh "新規作成" session. Mirrors `OtegamiM5ComposeSendUITests`'s
/// compose-button helper and `OtegamiPinSwipeListDisplayUITests`'s Settings
/// scroll helper.
final class OtegamiTemplatesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddTemplateAndInsertIntoBlankComposer() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        // --- Add a template in Settings ---
        let settingsTab = app.tabBars.buttons["設定"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()

        let templatesLink = app.buttons["settings.templatesLink"]
        XCTAssertTrue(scrollUntilVisible(templatesLink, in: app), "Expected the テンプレート settings entry point")
        templatesLink.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        let addButton = app.buttons["settings.templates.addButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()

        let nameField = app.textFields["templateEdit.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText("定例連絡")

        let subjectField = app.textFields["templateEdit.subject"]
        subjectField.tap()
        subjectField.typeText("定例のご連絡")

        let bodyEditor = app.textViews["templateEdit.body"]
        bodyEditor.tap()
        bodyEditor.typeText("いつもお世話になっております。")

        let saveButton = app.buttons["templateEdit.saveButton"]
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()

        let templateRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "定例連絡")).firstMatch
        XCTAssertTrue(templateRow.waitForExistence(timeout: 10), "Expected the newly added template to appear in the list")
        Thread.sleep(forTimeInterval: 2)

        // --- Back to Mail, open a blank Composer, insert the template ---
        let mailTab = app.tabBars.buttons["メール"]
        XCTAssertTrue(mailTab.waitForExistence(timeout: 5))
        mailTab.tap()

        let composeButton = app.buttons["mail.composeButton"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 10))
        composeButton.tap()

        // Below 添付ファイル in the Form, so it can start off-screen.
        let insertTemplateMenu = app.buttons["composer.insertTemplateMenu"]
        XCTAssertTrue(scrollUntilVisible(insertTemplateMenu, in: app), "Expected the テンプレートを挿入 menu once a global template exists")
        insertTemplateMenu.tap()

        let templateMenuItem = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "定例連絡")).firstMatch
        XCTAssertTrue(templateMenuItem.waitForExistence(timeout: 5))
        templateMenuItem.tap()

        // A blank composition (no subject, no body typed yet) should get
        // both the template's subject and body applied wholesale. Scroll
        // back up first — the Form's a List-backed lazy container, so the
        // subject/body fields (above 添付ファイル/テンプレート, scrolled off
        // the top to find the template menu above) may no longer be
        // materialized in the accessibility tree.
        let subjectComposer = app.textFields["composer.subject"]
        XCTAssertTrue(scrollUntilVisible(subjectComposer, in: app, direction: .up), "Expected to scroll back up to the subject field")
        XCTAssertEqual(subjectComposer.value as? String, "定例のご連絡")

        let bodyComposer = app.textViews["composer.body"]
        XCTAssertTrue(bodyComposer.waitForExistence(timeout: 5))
        XCTAssertTrue((bodyComposer.value as? String)?.contains("いつもお世話になっております。") == true)

        Thread.sleep(forTimeInterval: 4)
    }

    private enum ScrollDirection { case down, up }

    private func scrollUntilVisible(
        _ element: XCUIElement, in app: XCUIApplication, direction: ScrollDirection = .down, maxAttempts: Int = 10
    ) -> Bool {
        var found = element.waitForExistence(timeout: 3)
        let list = app.collectionViews.firstMatch
        var attempts = 0
        while !found, attempts < maxAttempts {
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: direction == .down ? 0.6 : 0.1))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: direction == .down ? 0.1 : 0.6))
            start.press(forDuration: 0.05, thenDragTo: end)
            found = element.waitForExistence(timeout: 2)
            attempts += 1
        }
        return found
    }
}
