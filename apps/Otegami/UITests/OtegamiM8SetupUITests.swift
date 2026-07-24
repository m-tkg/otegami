import XCTest

/// M8 verification, phase 1: add the Dovecot `test1` account (with SMTP
/// fields filled in too — this run also drives the Composer attachment
/// flow, phase 4 below, which needs to actually send) and confirm the
/// three new M8 seed fixtures (`14/15/16-*.eml`, added to `seed.sh`
/// alongside the pre-existing M1-M7 fixtures) all appear in the message
/// list before any attachment-specific phase runs.
final class OtegamiM8SetupUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddAccountShowsAttachmentSeedMessages() throws {
        let app = XCUIApplication()
        app.launch()

        addDovecotTest1AccountWithSMTP(in: app)
        restartAppToRecoverTouchDelivery(app)

        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 30))

        for subject in [
            "添付ファイルつきメール（PNG）",
            "添付ファイルつきメール（日本語ファイル名PDF）",
            "インライン画像つきHTMLメール",
        ] {
            XCTAssertTrue(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
                    .waitForExistence(timeout: 20),
                "Expected seed message \"\(subject)\" to appear in the message list"
            )
        }
    }
}
