import XCTest

/// M5 verification, phase 3: open a single-message thread ("ようこそ
/// otegami へ", no References — a plain baseline, not a multi-message
/// thread), tap "返信", confirm the Composer prefilled To/subject/quoted
/// body, and send. The host wrapper script asserts the sent message's
/// `In-Reply-To`/`References` headers via Mailpit's REST API afterward.
final class OtegamiM5ReplyUITests: XCTestCase {
    /// Shared with `scripts/verify-ios-m5.sh` — see `OtegamiM5ComposeSendUITests
    /// .subject`'s doc comment for why a fixed string is safe here.
    static let subject = "Re: ようこそ otegami へ"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testReplyPrefillsAndSends() throws {
        let app = XCUIApplication()
        app.launch()

        returnToSidebarRootIfNeeded(in: app)

        let list = app.collectionViews["messageList.list"]
        let row = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "ようこそ otegami へ")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Expected the seeded baseline thread to appear")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        let replyButton = app.buttons["messageDetail.replyButton"]
        XCTAssertTrue(replyButton.waitForExistence(timeout: 15), "Expected a 返信 button on the opened message")
        replyButton.tap()

        let subjectField = app.textFields["composer.subject"]
        XCTAssertTrue(subjectField.waitForExistence(timeout: 10), "Composer sheet did not appear")

        // Reply prefill (To/subject/body/references) resolves asynchronously
        // (`ComposerView.prepare()` reads the original message from GRDB) —
        // poll rather than asserting immediately after the sheet appears.
        let subjectPredicate = NSPredicate(format: "value == %@", Self.subject)
        let subjectExpectation = XCTNSPredicateExpectation(predicate: subjectPredicate, object: subjectField)
        XCTAssertEqual(
            XCTWaiter().wait(for: [subjectExpectation], timeout: 10), .completed,
            "Expected the subject field to prefill to \"\(Self.subject)\""
        )

        let toField = app.textFields["composer.to"]
        XCTAssertTrue((toField.value as? String)?.contains("team@otegami.test") == true, "Expected To to prefill with the original sender")

        let bodyField = app.textViews["composer.body"]
        XCTAssertTrue((bodyField.value as? String)?.contains("> ") == true, "Expected the body to be pre-quoted with \"> \"")

        let sendButton = app.buttons["composer.sendButton"]
        let enabledPredicate = NSPredicate(format: "isEnabled == true")
        let enabledExpectation = XCTNSPredicateExpectation(predicate: enabledPredicate, object: sendButton)
        XCTAssertEqual(XCTWaiter().wait(for: [enabledExpectation], timeout: 10), .completed, "Send button never became enabled")
        sendButton.tap()

        XCTAssertTrue(subjectField.waitForNonExistence(timeout: 15), "Composer sheet should dismiss after sending the reply")
    }
}
