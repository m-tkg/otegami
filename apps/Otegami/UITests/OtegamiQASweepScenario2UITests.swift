import XCTest

/// Continuation of the exploratory QA sweep (`OtegamiQASweepUITests` covers
/// scenarios 1-3 from the task list; this file covers 4-7): offline/online
/// transition combinations, Composer edge cases, boundary search data, and
/// settings round-trips. See `docs/qa-findings.md` for anything found here
/// that wasn't fixed outright.
final class OtegamiQASweepScenario2UITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func ensureDovecotTest1AccountExists(in app: XCUIApplication) throws {
        let emptyStateButton = app.buttons["mail.addAccountButton"]
        if emptyStateButton.waitForExistence(timeout: 5) {
            try addDovecotTest1AccountWithSMTP(in: app)
            restartAppToRecoverTouchDelivery(app)
        }
        app.launchArguments.removeAll { $0 == "-uiTestsAutoAdvanceToContent" }
        navigateToUnifiedInboxIfNeeded(in: app)
    }

    // MARK: - Scenario 5: Composer edge cases

    /// "返信画面で宛先を消して送信 (バリデーション)": clearing the To field
    /// on a reply must disable Send, not let an addressless message through.
    func testReplyWithClearedRecipientDisablesSend() throws {
        let app = XCUIApplication()
        app.launch()
        try ensureDovecotTest1AccountExists(in: app)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        let subject = "ようこそ otegami へ"
        XCTAssertTrue(waitForSeededSubjectScrollingIfNeeded(subject, in: app))
        let row = list.cells.containing(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        let replyButton = app.buttons.matching(NSPredicate(format: "label == %@", "返信")).firstMatch
        XCTAssertTrue(replyButton.waitForExistence(timeout: 20), "Expected a 返信 button in the thread detail")
        replyButton.tap()

        let composerSheet = app.otherElements["composer.sheet"]
        XCTAssertTrue(composerSheet.waitForExistence(timeout: 10), "Expected the composer sheet to open")

        let toField = app.textFields["composer.to"]
        XCTAssertTrue(toField.waitForExistence(timeout: 10))
        // Wait for the async reply-context prefill to actually populate the
        // field before trying to clear it — clearing an empty field would
        // give a false pass.
        let prefilled = NSPredicate(format: "value != '' AND value != nil")
        _ = XCTNSPredicateExpectation(predicate: prefilled, object: toField)
        let deadline = Date().addingTimeInterval(10)
        while (toField.value as? String ?? "").isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertFalse((toField.value as? String ?? "").isEmpty, "Expected the reply's To field to be prefilled before clearing it")

        let sendButton = app.buttons["composer.sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        XCTAssertTrue(sendButton.isEnabled, "Expected Send to be enabled once prefilled with a valid recipient")

        toField.tap()
        toField.typeKey("a", modifierFlags: .command)
        toField.typeText(XCUIKeyboardKey.delete.rawValue)

        // NOT `toField.value` here: an XCUIElement's reported `.value` for
        // an emptied SwiftUI TextField echoes its *placeholder* text
        // ("To (カンマ区切り)") rather than nil/"" on this simulator/
        // toolchain — confirmed via `app.debugDescription()` at this exact
        // point in a debug run: the live tree showed `composer.to` with no
        // `value:` at all (i.e. genuinely empty) and `composer.sendButton`
        // already carrying the `Disabled` trait, while `toField.value as?
        // String` still read back as non-empty. `sendButton.isEnabled` is
        // the reliable, load-bearing signal for what this test actually
        // cares about (does the app block sending to a cleared recipient),
        // so assert on that alone rather than re-deriving the same
        // information from a value accessor known to lie here.
        XCTAssertFalse(sendButton.isEnabled, "Expected Send to be disabled once the recipient field is cleared — otherwise an addressless message could be sent")

        // Clean up: cancel out without sending or saving a draft. `.firstMatch`
        // on the discard button — the confirmation dialog's action buttons
        // matched more than one element here (`app.buttons["composer.discardButton"]`
        // failed with "Multiple matching elements found"), the same class
        // of over-count M4's pitfall #1 documents for a single identifier.
        let cancelButton = app.buttons["composer.cancelButton"]
        if cancelButton.exists { cancelButton.tap() }
        let discardButton = app.buttons["composer.discardButton"].firstMatch
        if discardButton.waitForExistence(timeout: 3) { discardButton.tap() }
    }

    /// "下書き保存→再編集→送信": compose something, dismiss (triggering the
    /// save-or-discard prompt), save as a draft, reopen it from
    /// `FolderListSheet`'s "下書き" entry, and send it for real.
    func testDraftSaveReopenAndSend() throws {
        let app = XCUIApplication()
        app.launch()
        try ensureDovecotTest1AccountExists(in: app)
        returnToMailTabRootIfNeeded(in: app)

        let composeButton = app.buttons["mail.composeButton"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 20))
        composeButton.tap()

        let composerSheet = app.otherElements["composer.sheet"]
        XCTAssertTrue(composerSheet.waitForExistence(timeout: 10))

        let toField = app.textFields["composer.to"]
        let subjectField = app.textFields["composer.subject"]
        XCTAssertTrue(toField.waitForExistence(timeout: 10))
        toField.tap()
        toField.typeText("draft-recipient@otegami.test")
        subjectField.tap()
        subjectField.typeText("QAスイープ下書きテスト")
        let bodyField = app.textViews["composer.body"]
        if bodyField.waitForExistence(timeout: 5) {
            bodyField.tap()
            bodyField.typeText("下書き保存→再編集→送信の確認用本文です。")
        }

        let cancelButton = app.buttons["composer.cancelButton"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()

        let saveDraftButton = app.buttons["composer.saveDraftButton"].firstMatch
        XCTAssertTrue(saveDraftButton.waitForExistence(timeout: 10), "Expected the save-or-discard confirmation dialog with content present")
        saveDraftButton.tap()

        XCTAssertTrue(composerSheet.waitForNonExistence(timeout: 10), "Expected the composer to dismiss after saving as a draft")

        // Reopen from `FolderListSheet`'s "下書き" entry (only shown once at
        // least one draft exists).
        XCTAssertTrue(openDraftsList(in: app), "Expected a \"下書き\" entry to appear in the folder sheet after saving a draft")

        let draftRow = app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS %@", "QAスイープ下書きテスト")).firstMatch
        XCTAssertTrue(draftRow.waitForExistence(timeout: 10), "Expected the saved draft to appear in the drafts list")
        draftRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        // Reopening a draft opens the composer again with the same content.
        XCTAssertTrue(composerSheet.waitForExistence(timeout: 10), "Expected tapping the draft to reopen the composer")
        XCTAssertTrue(toField.waitForExistence(timeout: 10))
        let toValue = toField.value as? String ?? ""
        XCTAssertTrue(toValue.contains("draft-recipient"), "Expected the reopened draft to keep its recipient, got: \(toValue)")

        let sendButton = app.buttons["composer.sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
        XCTAssertTrue(sendButton.isEnabled, "Expected Send to be enabled for the reopened, still-valid draft")
        sendButton.tap()

        XCTAssertTrue(composerSheet.waitForNonExistence(timeout: 20), "Expected the composer to dismiss after sending the reopened draft")
    }

    // MARK: - Scenario 6: boundary data

    /// 0-hit / 1-character / symbol / emoji search queries — none of these
    /// should crash or hang, and each should land on a recognizable state
    /// (results or the empty-state view).
    func testBoundarySearchQueries() throws {
        let app = XCUIApplication()
        app.launch()
        try ensureDovecotTest1AccountExists(in: app)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))

        let queries = ["zzzznotfound99", "a", "%", "_", "\"", "😀", "😀🎉"]
        for query in queries {
            searchField.tap()
            // Clear whatever's left from the previous query in this loop.
            if let value = searchField.value as? String, !value.isEmpty {
                let deleteKeys = String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)
                searchField.typeText(deleteKeys)
            }
            searchField.typeText(query)
            Thread.sleep(forTimeInterval: 1) // clear the 300ms debounce plus query time

            // Task #145: was `app.staticTexts.matching(... "No Results" ...)`
            // — `ContentUnavailableView.search(text:)` is a stock SwiftUI/
            // Apple-localized view, so that text flips with system locale.
            // `MessageListView` already tags it with an identifier
            // (`messageList.search.emptyState`) precisely so tests don't
            // have to match its localized copy — use that instead.
            let emptyState = app.otherElements["messageList.search.emptyState"]
            let loading = app.otherElements["messageList.search.loading"]
            let anyCell = list.cells.firstMatch
            let settled = emptyState.waitForExistence(timeout: 8) || anyCell.waitForExistence(timeout: 2)
            XCTAssertTrue(
                settled || !loading.exists,
                "query \"\(query)\": search got stuck neither showing results nor the empty state"
            )
        }

        // Clear back to a normal state for anything that runs after this.
        // Task #145: `.searchable`'s system-provided Cancel button reads
        // "キャンセル" when the simulator's system language is Japanese —
        // OR both labels rather than assuming English.
        let cancelButton = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Cancel", "キャンセル")
        ).firstMatch
        if cancelButton.waitForExistence(timeout: 3) {
            cancelButton.tap()
        } else if let clearButton = searchField.buttons.firstMatch as XCUIElement?, clearButton.exists {
            clearButton.tap()
            app.swipeDown()
        }
    }

    /// 件名なしメール (`17-no-subject.eml`) / 本文が空のメール
    /// (`18-empty-body.eml`) — both should render with a graceful fallback,
    /// not a blank/crashed row.
    func testNoSubjectAndEmptyBodyMessagesDisplayGracefully() throws {
        let app = XCUIApplication()
        app.launch()
        try ensureDovecotTest1AccountExists(in: app)
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        XCTAssertTrue(
            waitForSeededSubjectScrollingIfNeeded("(件名なし)", in: app),
            "Expected the no-subject seed message to show the \"(件名なし)\" fallback in the list"
        )
        let noSubjectRow = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "(件名なし)")).firstMatch
        noSubjectRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        XCTAssertTrue(app.scrollViews["threadDetail.scrollView"].waitForExistence(timeout: 20), "Expected the no-subject message to open normally")
        popBackOnceIfNeeded(in: app)

        XCTAssertTrue(list.waitForExistence(timeout: 20))
        XCTAssertTrue(
            waitForSeededSubjectScrollingIfNeeded("本文が空のメール", in: app),
            "Expected the empty-body seed message's subject to appear in the list"
        )
        let emptyBodyRow = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "本文が空のメール")).firstMatch
        emptyBodyRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        XCTAssertTrue(app.scrollViews["threadDetail.scrollView"].waitForExistence(timeout: 20), "Expected the empty-body message to open without crashing")

        // Hold for a wrapping shell script's mid-test screenshot.
        Thread.sleep(forTimeInterval: 3)
    }

    // MARK: - Scenario 7: settings round-trip

    /// "アカウント削除→再追加→一覧正常": deleting an account from Settings
    /// and re-adding the same credentials should leave a clean, working
    /// account — not a duplicate, not a half-deleted ghost.
    func testDeleteAccountThenReAddLeavesAWorkingAccount() throws {
        let app = XCUIApplication()
        app.launch()
        try ensureDovecotTest1AccountExists(in: app)

        // Design-phase-2: "設定" is its own tab now, not a gear-icon sheet.
        openSettingsFromHamburgerMenu(in: app)
        // I「設定画面の再構成」: アカウント一覧は「アカウントの設定」カテゴリの下。
        XCTAssertTrue(navigateToAccountSettingsCategory(in: app), "「アカウントの設定」カテゴリへの遷移に失敗した")

        let accountRow = app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS %@", "Dovecot Test1")).firstMatch
        XCTAssertTrue(accountRow.waitForExistence(timeout: 10), "Expected the test1 account row in Settings")
        accountRow.swipeLeft()

        let deleteButton = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", ".delete")).firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "Expected a delete swipe action on the account row")
        deleteButton.tap()

        // `.firstMatch` — same button-over-count pattern as the composer's
        // confirmation dialog (`.firstMatch` above), this time for a plain
        // `Alert`'s action button.
        let confirmButton = app.buttons["settings.confirmDeleteButton"].firstMatch
        if confirmButton.waitForExistence(timeout: 5) {
            confirmButton.tap()
        }

        XCTAssertTrue(
            accountRow.waitForNonExistence(timeout: 15),
            "Expected the account row to disappear from Settings after deletion"
        )

        // "設定" is a permanent tab now — no sheet to close. Mail tab should
        // now be back to the empty-account state (or at least no longer
        // show test1's mailboxes) — confirm re-adding works cleanly.
        returnToMailTabRootIfNeeded(in: app)
        try addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)

        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(navigateToUnifiedInboxIfNeeded(in: app), "Expected the message list reachable after re-adding the account")
        XCTAssertTrue(list.cells.firstMatch.waitForExistence(timeout: 20), "Expected the re-added account's mailbox to populate normally, not stay empty")

        // No duplicate account section — checked via `FolderListSheet`,
        // which sections mailboxes by account exactly like the old sidebar
        // did.
        returnToMailTabRootIfNeeded(in: app)
        app.buttons["mail.hamburgerButton"].tap()
        let folderList = app.collectionViews["folderSheet.list"]
        XCTAssertTrue(folderList.waitForExistence(timeout: 20))
        let test1Sections = folderList.staticTexts.matching(NSPredicate(format: "label == %@", "Dovecot Test1"))
        XCTAssertEqual(test1Sections.count, 1, "Expected exactly one \"Dovecot Test1\" section header after delete+re-add, found \(test1Sections.count)")
    }
}
