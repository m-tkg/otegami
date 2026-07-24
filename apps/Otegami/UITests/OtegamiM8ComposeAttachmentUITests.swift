import XCTest

/// M8 verification, phase 2 (c): compose a brand-new message with the
/// `OTEGAMI_UITEST_ATTACH_FIXTURE` internal hook (`ComposerView
/// .attachUITestFixtureIfRequested`) standing in for driving the system
/// file picker (out of XCUITest's reach — see that method's doc comment),
/// confirm the attached fixture appears in the Composer's attachment list,
/// then send. `scripts/verify-ios-m8.sh` polls Mailpit's REST API
/// afterward to confirm the attachment's filename actually made it onto
/// the wire.
final class OtegamiM8ComposeAttachmentUITests: XCTestCase {
    /// Shared with `scripts/verify-ios-m8.sh`'s host-side Mailpit polling
    /// — a fixed string is safe here for the same reason
    /// `OtegamiM5ComposeSendUITests.subject` documents (Mailpit's message
    /// store is cleared before this phase runs).
    static let subject = "otegami M8 添付送信テスト"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testComposeWithAttachmentAndSend() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OTEGAMI_UITEST_ATTACH_FIXTURE"] = "1"
        app.launch()

        returnToSidebarRootIfNeeded(in: app)

        let composeButton = app.buttons["sidebar.composeButton"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 10), "Compose toolbar button should exist")
        composeButton.tap()

        let toField = app.textFields["composer.to"]
        XCTAssertTrue(toField.waitForExistence(timeout: 10), "Composer sheet did not appear")

        // The internal test hook attaches its fixture during `Composer
        // View.prepare()` (`.task`), asynchronously — poll rather than
        // asserting immediately.
        let attachmentRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "m8-uitest-attachment.txt")).firstMatch
        XCTAssertTrue(attachmentRow.waitForExistence(timeout: 10), "Expected the UITest fixture attachment to appear in the Composer")

        type("recipient@otegami.test", into: toField)
        type(Self.subject, into: app.textFields["composer.subject"])

        let bodyField = app.textViews["composer.body"]
        XCTAssertTrue(bodyField.waitForExistence(timeout: 5))
        bodyField.tap()
        bodyField.typeText("添付ファイル付きの送信テストです。")

        let sendButton = app.buttons["composer.sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        XCTAssertTrue(sendButton.isEnabled, "Send button should be enabled once To/subject are filled")
        sendButton.tap()

        XCTAssertTrue(
            toField.waitForNonExistence(timeout: 15),
            "Composer sheet should dismiss once the message is enqueued and sent"
        )
    }
}
