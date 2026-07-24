import XCTest

/// M5 verification, phase 2: compose a brand-new message from scratch and
/// send it. The host wrapper script (`scripts/verify-ios-m5.sh`) polls
/// Mailpit's REST API and `doveadm` for the server-side effects afterward
/// (this XCUITest, running inside the simulator, can't shell out itself —
/// see `verify.md`'s note on `Foundation.Process` being unavailable there).
final class OtegamiM5ComposeSendUITests: XCTestCase {
    /// Shared with `scripts/verify-ios-m5.sh`'s host-side Mailpit/doveadm
    /// polling — kept as a fixed string (not a per-run UUID) since the
    /// script always clears Mailpit's message store and re-seeds/expunges
    /// the mailstack before this phase runs, so there's no cross-run
    /// collision risk to guard against.
    static let subject = "otegami M5 新規送信テスト"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testComposeAndSendNewMessage() throws {
        let app = XCUIApplication()
        app.launch()

        // A fresh launch (no prior thread ever opened in this run) already
        // starts at the sidebar/unified-inbox; belt-and-suspenders in case
        // a previous phase in the same simulator install left a thread
        // restored.
        returnToSidebarRootIfNeeded(in: app)

        let composeButton = app.buttons["sidebar.composeButton"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 10), "Compose toolbar button should exist")
        XCTAssertTrue(composeButton.isEnabled, "Compose button should be enabled once an account exists")
        composeButton.tap()

        let toField = app.textFields["composer.to"]
        XCTAssertTrue(toField.waitForExistence(timeout: 10), "Composer sheet did not appear")
        type("recipient@otegami.test", into: toField)
        type(Self.subject, into: app.textFields["composer.subject"])

        let bodyField = app.textViews["composer.body"]
        XCTAssertTrue(bodyField.waitForExistence(timeout: 5))
        bodyField.tap()
        bodyField.typeText("これは M5 の新規作成送信テストです。\n日本語本文を含みます。")

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
