import XCTest

/// M8 verification, phase 2 (a): open the PNG-attachment seed message
/// (`14-attachment-png.eml`), confirm the attachment section renders a row
/// for `logo.png`, tap it (not yet downloaded — this exercises the
/// "タップ → スピナー付き取得 → QuickLook プレビュー" path), and confirm a
/// QuickLook-style preview appears (a new navigation bar becomes reachable;
/// the exact system chrome inside `.quickLookPreview`'s sheet isn't
/// something XCUITest can assert precise labels for — see the doc comment
/// below). `scripts/verify-ios-m8.sh` screenshots mid-test (the same
/// "screenshot during, not after, a non-persisted screen" technique M6/M7
/// established) for a human/Claude visual read of the actual preview
/// content.
final class OtegamiM8AttachmentUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTappingAttachmentRowOpensQuickLookPreview() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        let list = app.collectionViews["messageList.list"]
        let row = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "添付ファイルつきメール（PNG）")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Expected the PNG-attachment seed message to appear")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        // The attachment row's identifier is stable (`messageDetail
        // .attachment.<id>`) even before the id is known to this test, so
        // find it by its filename label instead — same "label, not exact
        // identifier" fallback `verify.md`'s M2/M4/M7 pitfalls document for
        // this simulator/toolchain.
        let attachmentRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "logo.png")).firstMatch
        XCTAssertTrue(attachmentRow.waitForExistence(timeout: 15), "Expected an attachment row for logo.png")
        attachmentRow.tap()

        // QuickLook's own preview sheet is system UI (`.quickLookPreview`),
        // not this app's SwiftUI hierarchy — its navigation bar's exact
        // button labels/identifiers aren't something this app controls or
        // should assert on directly. A new navigation bar becoming
        // reachable (over and above `MessageView`'s own, already-present
        // one) is the signal a preview screen was actually presented; the
        // wrapping shell script's mid-test screenshot is what actually
        // confirms *what* it shows.
        let navigationBars = app.navigationBars
        let previewAppeared = NSPredicate(format: "count > 1")
        let expectation = XCTNSPredicateExpectation(predicate: previewAppeared, object: navigationBars)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 20), .completed,
            "Expected a QuickLook preview navigation bar to appear after downloading and opening the attachment"
        )

        // Hold the preview on screen for a window wide enough for the
        // wrapping shell script's background screenshot subshell to land
        // inside it — same technique as M6/M7's non-persisted-screen
        // captures (see verify.md).
        Thread.sleep(forTimeInterval: 4)
    }
}
