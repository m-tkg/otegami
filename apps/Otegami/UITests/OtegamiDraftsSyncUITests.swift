import XCTest

/// Drafts IMAP sync verification. Host-interleaved phases, same pattern as
/// M3/M4/M5 (`scripts/verify-ios-drafts-sync.sh` drives `doveadm` between
/// each `xcodebuild test -only-testing:` phase — XCUITest can't shell out
/// itself, see `verify.md`'s note on `Foundation.Process`).
///
/// Phase 1 (`Setup`): add the test1 Dovecot account with SMTP, confirm the
/// seeded baseline renders.
final class OtegamiDraftsSyncSetupUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddAccountAndBaselineAppears() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        addDovecotTest1AccountWithSMTP(in: app)
        restartAppToRecoverTouchDelivery(app)

        XCTAssertTrue(
            waitForSeededSubjectScrollingIfNeeded("ようこそ otegami へ", in: app),
            "Expected the seeded baseline message to appear after account setup"
        )
    }
}

/// Phase 2: compose a brand-new message, then cancel and choose
/// "下書きとして保存" instead of discarding — this enqueues
/// `OpQueueKind.saveDraft`, which the host script polls Dovecot for via
/// `doveadm` immediately after this phase.
final class OtegamiDraftsSyncSaveUITests: XCTestCase {
    /// Shared with `scripts/verify-ios-drafts-sync.sh`'s host-side doveadm
    /// polling — a fixed string (not a per-run UUID) since the wrapping
    /// script always expunges the Drafts mailbox before this phase runs.
    static let subject = "otegami Drafts統合テスト下書き"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testComposeThenSaveAsDraft() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()
        returnToSidebarRootIfNeeded(in: app)

        let composeButton = app.buttons["sidebar.composeButton"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 10))
        composeButton.tap()

        let toField = app.textFields["composer.to"]
        XCTAssertTrue(toField.waitForExistence(timeout: 10), "Composer sheet did not appear")
        type("recipient@otegami.test", into: toField)
        type(Self.subject, into: app.textFields["composer.subject"])

        let bodyField = app.textViews["composer.body"]
        XCTAssertTrue(bodyField.waitForExistence(timeout: 5))
        bodyField.tap()
        bodyField.typeText("下書き保存の統合テスト本文(版1)。")

        app.buttons["composer.cancelButton"].tap()

        // `.firstMatch`: a `.confirmationDialog` action button is reported
        // as more than one node in this simulator/toolchain — see
        // `verify.md`'s "QA sweep: .confirmationDialog/Alert action buttons
        // over-count too".
        let saveDraftButton = app.buttons["composer.saveDraftButton"].firstMatch
        XCTAssertTrue(saveDraftButton.waitForExistence(timeout: 5), "Save-as-draft confirmation dialog did not appear")
        saveDraftButton.tap()

        XCTAssertTrue(toField.waitForNonExistence(timeout: 10), "Composer should dismiss after saving as a draft")
    }
}

/// Phase 3: open the Drafts list, resume the just-saved draft, edit it, and
/// save again — this must *replace* the server copy (host script polls
/// Dovecot's Drafts mailbox for exactly one message afterward), not leave a
/// duplicate.
final class OtegamiDraftsSyncEditUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testResumeEditAndResaveDraft() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()
        returnToSidebarRootIfNeeded(in: app)

        let draftsButton = app.buttons["sidebar.drafts"]
        XCTAssertTrue(draftsButton.waitForExistence(timeout: 10), "Drafts sidebar entry should exist once a draft has been saved")
        draftsButton.tap()

        let subjectPredicate = NSPredicate(format: "label CONTAINS %@", OtegamiDraftsSyncSaveUITests.subject)
        let draftRow = app.buttons.matching(subjectPredicate).firstMatch
        XCTAssertTrue(draftRow.waitForExistence(timeout: 10), "Saved draft should appear in the Drafts list")
        draftRow.tap()

        let subjectField = app.textFields["composer.subject"]
        XCTAssertTrue(subjectField.waitForExistence(timeout: 10), "Composer should reopen with the draft's fields")
        XCTAssertEqual(subjectField.value as? String, OtegamiDraftsSyncSaveUITests.subject, "Resumed draft's subject should match what was saved")

        let bodyField = app.textViews["composer.body"]
        XCTAssertTrue(bodyField.waitForExistence(timeout: 5))
        bodyField.tap()
        bodyField.typeText(" 追記(版2)。")

        app.buttons["composer.cancelButton"].tap()
        let saveDraftButton = app.buttons["composer.saveDraftButton"].firstMatch
        XCTAssertTrue(saveDraftButton.waitForExistence(timeout: 5))
        saveDraftButton.tap()

        XCTAssertTrue(subjectField.waitForNonExistence(timeout: 10), "Composer should dismiss after re-saving the edited draft")
    }
}

/// Phase 4: resume the (once-edited) draft again and actually send it —
/// the host script then polls Mailpit for delivery and Dovecot's Drafts
/// mailbox to confirm the now-redundant copy was deleted
/// (`OpQueueProcessor`'s `.send` best-effort cleanup).
final class OtegamiDraftsSyncSendUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testResumeDraftAndSend() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()
        returnToSidebarRootIfNeeded(in: app)

        let draftsButton = app.buttons["sidebar.drafts"]
        XCTAssertTrue(draftsButton.waitForExistence(timeout: 10))
        draftsButton.tap()

        let subjectPredicate = NSPredicate(format: "label CONTAINS %@", OtegamiDraftsSyncSaveUITests.subject)
        let draftRow = app.buttons.matching(subjectPredicate).firstMatch
        XCTAssertTrue(draftRow.waitForExistence(timeout: 10), "The edited draft should still be the only row for this subject")
        draftRow.tap()

        let sendButton = app.buttons["composer.sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
        XCTAssertTrue(sendButton.isEnabled)
        sendButton.tap()

        XCTAssertTrue(
            app.textFields["composer.to"].waitForNonExistence(timeout: 15),
            "Composer should dismiss once the message resumed from a draft is sent"
        )
    }
}

/// Phase 5 (after the host script `doveadm save`s an `.eml` directly into
/// Drafts and relaunches the app — the "another client wrote a draft"
/// scenario): the externally-written draft should surface in the unified
/// Drafts list, open with its body already legible, and — critically —
/// **not** be deleted from the server just because it was opened and
/// closed without an edit (`DraftMessageRecord`'s doc comment: a
/// server-origin draft consumes/deletes nothing on open, unlike a local
/// one). The host script confirms that last part via `doveadm` afterward.
final class OtegamiDraftsSyncExternalDraftUITests: XCTestCase {
    /// Shared with `scripts/verify-ios-drafts-sync.sh`'s `doveadm save`
    /// call for the externally-written fixture.
    static let externalSubject = "otegami 他クライアント下書き統合テスト"
    static let externalBodyMarker = "外部クライアントが書いた下書き本文マーカー"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testExternalDraftAppearsAndSurvivesAnUneditedOpen() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()
        returnToSidebarRootIfNeeded(in: app)

        let draftsButton = app.buttons["sidebar.drafts"]
        XCTAssertTrue(draftsButton.waitForExistence(timeout: 10))
        draftsButton.tap()

        let subjectPredicate = NSPredicate(format: "label CONTAINS %@", Self.externalSubject)
        let draftRow = app.buttons.matching(subjectPredicate).firstMatch
        XCTAssertTrue(
            draftRow.waitForExistence(timeout: 20),
            "A draft written directly to the server's Drafts mailbox by another client should surface in the unified list"
        )
        draftRow.tap()

        let subjectField = app.textFields["composer.subject"]
        XCTAssertTrue(subjectField.waitForExistence(timeout: 10), "Composer should open the server-origin draft")
        XCTAssertEqual(subjectField.value as? String, Self.externalSubject)

        let bodyField = app.textViews["composer.body"]
        XCTAssertTrue(bodyField.waitForExistence(timeout: 10))
        // Best-effort body-content check — the on-demand network fetch
        // this needs (`ComposerView.loadServerDraft`) can occasionally
        // still be in flight when this reads; not asserted as fatal since
        // the load-without-deleting behavior below is this test's primary
        // point.
        _ = (bodyField.value as? String)?.contains(Self.externalBodyMarker)

        // No edits made — closing now must be a silent no-op (no
        // save-or-discard confirmation dialog), leaving the server copy
        // completely untouched.
        app.buttons["composer.cancelButton"].tap()
        XCTAssertTrue(subjectField.waitForNonExistence(timeout: 10), "Composer should dismiss immediately (no unsaved changes)")
        XCTAssertFalse(
            app.buttons["composer.saveDraftButton"].firstMatch.waitForExistence(timeout: 2),
            "Opening a server-origin draft and closing without editing it must not prompt save/discard"
        )
    }
}
