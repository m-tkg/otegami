import XCTest

/// 実機フィードバック第3弾の目視確認用スクリーンショット — E (設定の日英
/// 混在解消)/H (アカウントフォームのフィールドラベル)/I (設定カテゴリ
/// 再配置)/J (ハンバーガー閉じるボタンのアイコン化) を、dev mailstack の
/// Dovecot 接続を一切必要としない範囲でカバーする。K (アカウントセクション
/// 折りたたみ) は少なくとも1つの保存済みアカウントが必要
/// (`AccountSetupView.saveAccount()`は`testSucceeded`が真である前提) で、
/// このセッション中に発生したシミュレータの既知の環境障害
/// (`docs/verify.md`の「実機フィードバック第3弾」節参照 — Otegami アプリの
/// プロセスだけが `localhost:1143` へ接続できない) により未確認のまま
/// 残っている。
final class OtegamiFeedbackBatch3ScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// I: 設定ルートのカテゴリ一覧 (4カテゴリ + 「このアプリについて」)。
    /// J: 同じ画面を開く導線上、ハンバーガーメニューの「閉じる」がアイコン
    /// のみになっていることも同じ screenshot で確認できる (別ステップで
    /// メニューへ戻ったときの見た目)。
    func testSettingsRootShowsReorganizedCategories() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        openSettingsFromHamburgerMenu(in: app)

        // Task #189: 「一般」カテゴリが先頭に追加された.
        XCTAssertTrue(app.buttons["settings.category.general"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["settings.category.accounts"].exists)
        XCTAssertTrue(app.buttons["settings.category.mailViewer"].exists)
        XCTAssertTrue(app.buttons["settings.category.mailList"].exists)
        XCTAssertTrue(app.buttons["settings.category.mailCompose"].exists)
        XCTAssertTrue(app.buttons["settings.aboutLink"].exists)
        // I: 「その他」カテゴリは廃止済み.
        XCTAssertFalse(app.buttons["settings.category.other"].exists)

        attachScreenshot(named: "I-settings-root-categories")
    }

    /// Task #189: 「一般」カテゴリに iCloud 同期トグルが移設されている
    /// ことを確認 (旧「アカウントの設定」カテゴリの項目 — Task #186 で
    /// 同期対象がアカウントの接続設定を超えて設定全般に広がったため、
    /// 新設カテゴリへ再移設した)。
    ///
    /// Task #212: プッシュ通知への入口も「一般」へ再移設された
    /// (`GeneralSettingsView`の doc comment参照 — 以前は「アカウントの
    /// 設定」カテゴリにあった。旧`testAccountSettingsCategoryShowsMigratedItems`
    /// が確認していた内容はここへ統合し、そのテストは削除した)。
    func testGeneralSettingsCategoryShowsCloudSyncToggle() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        openSettingsFromHamburgerMenu(in: app)
        XCTAssertTrue(navigateToGeneralSettingsCategory(in: app), "「一般」カテゴリへの遷移に失敗した")

        XCTAssertTrue(app.switches["settings.cloudSyncToggle"].waitForExistence(timeout: 10))
        XCTAssertTrue(scrollSettingsUntilVisible(app.buttons["settings.pushNotificationsLink"], in: app))

        attachScreenshot(named: "I-general-settings-category")
    }

    /// E/I: 「メールビューア」カテゴリに画像設定・HTML表示設定が
    /// 移設されていることを確認 (旧「その他」カテゴリの項目)。
    func testMailViewerSettingsCategoryShowsMigratedItems() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        openSettingsFromHamburgerMenu(in: app)
        XCTAssertTrue(navigateToMailViewerSettingsCategory(in: app), "「メールビューア」カテゴリへの遷移に失敗した")

        XCTAssertTrue(app.switches["settings.aiFeaturesToggle"].waitForExistence(timeout: 10))
        XCTAssertTrue(scrollSettingsUntilVisible(app.switches["settings.images.autoShowEmbeddedToggle"], in: app))
        XCTAssertTrue(scrollSettingsUntilVisible(app.switches["settings.html.alwaysShowPlainTextToggle"], in: app))

        attachScreenshot(named: "I-mail-viewer-settings-category")
    }

    /// I (新設): 「メール作成」カテゴリにテンプレート・署名テンプレート・
    /// 送信キャンセルの猶予がまとまっていることを確認。
    func testMailComposeSettingsCategoryShowsAllThreeItems() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        openSettingsFromHamburgerMenu(in: app)
        XCTAssertTrue(navigateToMailComposeSettingsCategory(in: app), "「メール作成」カテゴリへの遷移に失敗した")

        XCTAssertTrue(app.buttons["settings.templatesLink"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["settings.signaturesLink"].exists)
        #if os(iOS)
        XCTAssertTrue(app.buttons["settings.sendCancelWindowPicker"].exists)
        #endif

        attachScreenshot(named: "I-mail-compose-settings-category")
    }

    /// H: アカウント追加フォーム (`AccountSetupView`) の各フィールドに
    /// 永続ラベルが表示されていることを確認 — dev mailstack への接続は
    /// 不要 (フォームの見た目だけを確認するため、接続テストは行わない)。
    func testAccountSetupFormShowsPersistentFieldLabels() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        app.buttons["mail.addAccountButton"].tap()
        let otherButton = app.buttons["accountTypeSelection.otherButton"]
        XCTAssertTrue(otherButton.waitForExistence(timeout: 10))
        otherButton.tap()

        XCTAssertTrue(app.textFields["accountSetup.displayName"].waitForExistence(timeout: 10))
        // H: プレースホルダだけでなく、常時表示のラベル文字列自体が
        // 画面上に存在することを確認する — `LabeledContent`のラベルは
        // フィールドとは別の`StaticText`として描画される。厳密一致の
        // `app.staticTexts["表示名"]`(identifier/label のsubscript検索)
        // はこのシミュレータ/toolchain で「画面に明らかに存在する要素を
        // 見つけられない」既知のクラスの問題を踏む (`docs/verify.md`の
        // M2/M4/M7節) — `label CONTAINS`述語に切り替えて確実に検索する。
        // 日英どちらのラベルにもマッチするよう`OR`述語にする (シミュレータ
        // の既定システム言語がこの開発機では英語 — `docs/localization.md`
        // の実機フィードバック第2弾 (3) 節 — なので E で追加した英訳が
        // 実際には描画される。ラベルテキストの言語に依存せず「常時表示の
        // ラベルが存在すること」自体を確認するのがこのテストの目的)。
        func label(ja: String, en: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", ja, en)).firstMatch
        }
        XCTAssertTrue(label(ja: "表示名", en: "Display Name").exists, "Expected a persistent display-name label, not just a placeholder")
        XCTAssertTrue(label(ja: "メールアドレス", en: "Email Address").exists)
        XCTAssertTrue(scrollUntilVisible(label(ja: "ホスト", en: "Host"), in: app))
        XCTAssertTrue(label(ja: "ポート", en: "Port").exists)
        XCTAssertTrue(label(ja: "ユーザー名", en: "Username").exists)
        XCTAssertTrue(label(ja: "パスワード", en: "Password").exists)

        attachScreenshot(named: "H-account-setup-field-labels")
    }

    private func attachScreenshot(named name: String) {
        Thread.sleep(forTimeInterval: 1)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Mirrors the identical private helper in `OtegamiDuplicateAccountUITests`/
    // `OtegamiPinSwipeListDisplayUITests` etc. — each verification suite in
    // this directory keeps its own copy rather than sharing one, matching
    // this file's existing convention (`DovecotAccountUITestHelpers` only
    // holds helpers used across *many* suites).
    @discardableResult
    private func scrollSettingsUntilVisible(_ element: XCUIElement, in app: XCUIApplication, maxAttempts: Int = 10) -> Bool {
        var found = element.waitForExistence(timeout: 3)
        let list = app.collectionViews.firstMatch
        var attempts = 0
        while !found, attempts < maxAttempts {
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            start.press(forDuration: 0.05, thenDragTo: end)
            found = element.waitForExistence(timeout: 2)
            attempts += 1
        }
        return found
    }

    @discardableResult
    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication, maxAttempts: Int = 10) -> Bool {
        var found = element.waitForExistence(timeout: 3)
        let list = app.collectionViews.firstMatch
        var attempts = 0
        while !found, attempts < maxAttempts {
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            start.press(forDuration: 0.05, thenDragTo: end)
            found = element.waitForExistence(timeout: 2)
            attempts += 1
        }
        return found
    }
}
