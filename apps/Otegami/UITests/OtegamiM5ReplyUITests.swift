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

        // Deliberately *not* `returnToSidebarRootIfNeeded` — no thread has
        // been opened yet this run (the earlier compose-only phase never
        // views a message), so a cold launch already lands on the message
        // list (content column, unified inbox auto-selected) with nothing
        // to navigate back from; popping to the sidebar here would leave
        // `messageList.list` unreachable instead. See M2's "cold relaunch
        // re-selects the first INBOX automatically" note in verify.md.
        let list = app.collectionViews["messageList.list"]
        let row = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "ようこそ otegami へ")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Expected the seeded baseline thread to appear")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        // Identifier-based lookup doesn't work here: `ThreadDetailView`
        // applies its own `.accessibilityIdentifier("threadDetail.message
        // .<id>.body")` to the whole embedded `MessageView`, and every
        // descendant accessibility element inside — including the reply
        // button's own `.accessibilityIdentifier("messageDetail
        // .replyButton")` — reports that *outer* container's identifier
        // instead of its own (confirmed via `app.debugDescription`: the
        // button element shows `identifier: 'threadDetail.message.2.body'`,
        // not `'messageDetail.replyButton'`) — the same "container identifier
        // leaks onto descendants" behavior verify.md's M4 pitfall #1
        // already documented, just total override here rather than
        // over-counting. A label match sidesteps it entirely (same
        // workaround as M2's "画像を表示" banner button).
        let replyButton = app.buttons.matching(NSPredicate(format: "label == %@", "返信")).firstMatch
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
