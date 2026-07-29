import XCTest

/// Task #73 (「ハンバーガーメニューは開いた時は基本全て折りたたまれてる状態に
/// して、今選択されてるやつだけが開かれているようにして」) を実機シミュレータ
/// で確認する UITest — `OtegamiTask52HamburgerMenuUITests`と同じフィクスチャ
/// (`OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT`: INBOX/All Mail/Sent Mail の
/// 3メールボックスを持つ Fake Gmail アカウント1件) と「要素解決→即アクション」
/// の流儀を踏襲する。
final class OtegamiTask73HamburgerMenuCollapseUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// `AccountSectionHeader`/`CategorySectionHeader`の`.accessibilityValue`は
    /// ソース文字列 (`"折りたたみ"`/`"展開"`) をそのまま渡しているが、この
    /// アプリは String Catalog (`Localizable.xcstrings`, `CLAUDE.md`の
    /// 「String Catalog 日英」) 経由で英語にも訳されているため、シミュレータの
    /// 実行言語が英語だと XCUITest 側で観測される`.value`は英訳後の
    /// `"Collapsed"`/`"Expanded"`になる — どちらの言語でも判定できるよう、
    /// 完全一致の文字列比較ではなくこのヘルパーで判定する。
    private func isCollapsedValue(_ value: String?) -> Bool {
        value == "折りたたみ" || value == "Collapsed"
    }

    private func isExpandedValue(_ value: String?) -> Bool {
        value == "展開" || value == "Expanded"
    }

    /// デフォルト選択 (`.unifiedInbox`、どのカテゴリ・アカウントにも属さない)
    /// でメニューを開くと、カテゴリセクション・アカウントセクションどちらも
    /// 折りたたまれているはず。
    func testMenuOpensFullyCollapsedByDefault() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT"] = "1"
        app.launch()

        app.buttons["mail.hamburgerButton"].tap()
        XCTAssertTrue(app.collectionViews["folderSheet.list"].waitForExistence(timeout: 10), "ハンバーガーメニューが開かなかった")

        // Task #110: 折りたたみ開閉の accessibility state は見出し行本体
        // (`.header` — 統合ビュー選択のタップ対象に変わった) ではなく、
        // 独立したシェブロン (`.chevron`) 側が持つ。
        let inboxCategoryChevron = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "folderSheet.category.inbox.chevron"))
            .firstMatch
        XCTAssertTrue(inboxCategoryChevron.waitForExistence(timeout: 10), "「受信トレイ」カテゴリのシェブロンが見つからない")
        XCTAssertTrue(
            isCollapsedValue(inboxCategoryChevron.value as? String),
            "「すべての受信トレイ」選択中は「受信トレイ」カテゴリも折りたたまれているべき — value=\(String(describing: inboxCategoryChevron.value))"
        )

        let accountHeader = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@ AND label CONTAINS %@", "folderSheet.account.", "Fake Gmail"))
            .firstMatch
        XCTAssertTrue(accountHeader.waitForExistence(timeout: 10), "アカウントセクション見出しが見つからない")
        XCTAssertTrue(
            isCollapsedValue(accountHeader.value as? String),
            "「すべての受信トレイ」選択中は account セクションも折りたたまれているべき — value=\(String(describing: accountHeader.value))"
        )

        // 概観のスクリーンショット用に画面を保持する (この後に要素解決/
        // アクションは無い)。
        Thread.sleep(forTimeInterval: 4)
    }

    /// 単一メールボックス (アカウント優先セクションの INBOX 行) を選択して
    /// メニューを閉じ、再度開くと: そのアカウントのセクションと、role が一致
    /// するカテゴリ (受信トレイ) だけが展開され、無関係なカテゴリ (アーカイブ)
    /// は折りたたまれたままであるはず。
    func testReopeningMenuExpandsOnlySelectedMailboxSection() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT"] = "1"
        app.launch()

        app.buttons["mail.hamburgerButton"].tap()
        XCTAssertTrue(app.collectionViews["folderSheet.list"].waitForExistence(timeout: 10), "ハンバーガーメニューが開かなかった")

        // 手動でアカウント優先セクションを展開する (「シートを開いている間の
        // 手動開閉は従来どおり自由」— この操作自体が壊れていないことも兼ねて
        // 確認する)。
        let accountHeader = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@ AND label CONTAINS %@", "folderSheet.account.", "Fake Gmail"))
            .firstMatch
        XCTAssertTrue(accountHeader.waitForExistence(timeout: 10), "アカウントセクション見出しが見つからない")
        accountHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        let inboxRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@ AND identifier CONTAINS %@", "folderSheet.mailbox.", ".INBOX"))
            .firstMatch
        XCTAssertTrue(inboxRow.waitForExistence(timeout: 10), "展開後、INBOX 行が見つからない")
        inboxRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        // メールボックスを選択するとメニューは自動で閉じ、一覧に遷移する
        // (`MailScreenView.selectMailbox`)。
        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 10), "メールボックス選択後、一覧に戻らなかった")

        // 再度開く — Task #73 の「開いた時は全折りたたみ＋選択中のみ展開」の
        // リセットが走るはず。
        app.buttons["mail.hamburgerButton"].tap()
        XCTAssertTrue(app.collectionViews["folderSheet.list"].waitForExistence(timeout: 10), "ハンバーガーメニューの再オープンに失敗した")

        let reopenedAccountHeader = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@ AND label CONTAINS %@", "folderSheet.account.", "Fake Gmail"))
            .firstMatch
        XCTAssertTrue(reopenedAccountHeader.waitForExistence(timeout: 10), "再オープン後、アカウントセクション見出しが見つからない")
        XCTAssertTrue(
            isExpandedValue(reopenedAccountHeader.value as? String),
            "選択中メールボックスの属する account セクションは展開されているべき — value=\(String(describing: reopenedAccountHeader.value))"
        )

        // Task #110: 折りたたみ開閉の accessibility state は`.chevron`側。
        let reopenedInboxCategoryChevron = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "folderSheet.category.inbox.chevron"))
            .firstMatch
        XCTAssertTrue(reopenedInboxCategoryChevron.waitForExistence(timeout: 10), "再オープン後、「受信トレイ」カテゴリのシェブロンが見つからない")
        XCTAssertTrue(
            isExpandedValue(reopenedInboxCategoryChevron.value as? String),
            "選択中メールボックスの role (受信トレイ) に対応するカテゴリも展開されているべき — value=\(String(describing: reopenedInboxCategoryChevron.value))"
        )

        let reopenedArchiveCategoryChevron = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "folderSheet.category.archive.chevron"))
            .firstMatch
        XCTAssertTrue(reopenedArchiveCategoryChevron.waitForExistence(timeout: 10), "再オープン後、「アーカイブ」カテゴリのシェブロンが見つからない")
        XCTAssertTrue(
            isCollapsedValue(reopenedArchiveCategoryChevron.value as? String),
            "選択と無関係なカテゴリ (アーカイブ) は折りたたまれたままであるべき — value=\(String(describing: reopenedArchiveCategoryChevron.value))"
        )

        // スクリーンショット用に画面を保持する (この後に要素解決/アクションは
        // 無い)。
        Thread.sleep(forTimeInterval: 4)
    }
}
