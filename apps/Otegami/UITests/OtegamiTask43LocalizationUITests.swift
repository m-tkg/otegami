import XCTest

/// タスク#43 (設定まわり3点バッチ) の検証用スクリーンショット:
/// - 2「設定画面の閉じるボタンをバツに」— `SettingsSheetView`の閉じる
///   ボタンが xmark アイコンのみになっていることを目視確認する
///   (`settingsSheet.closeButton`の見た目)。
/// - 3「設定画面の日英混在解消」— 設定の4カテゴリ + このアプリについてを
///   日本語/英語それぞれで撮り、混在が無いことを目視確認する。
///
/// `-AppleLanguages`/`-AppleLocale` launch argument はプロセス起動時だけ
/// 有効なテスト専用の言語指定で、`LocalizationSettingsStore`が扱う
/// `UserDefaults`の`AppleLanguages`キー (OS の「アプリごとの言語」/旧
/// 表示言語ピッカーが書き込んでいたもの) とは別物 — このテストはタスク#43
/// (1) で削除した移行処理の影響を受けない、独立した言語指定経路。
final class OtegamiTask43LocalizationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSettingsScreensInJapanese() throws {
        try walkSettingsScreens(appleLanguages: "(ja)", appleLocale: "ja_JP", tagPrefix: "ja")
    }

    func testSettingsScreensInEnglish() throws {
        try walkSettingsScreens(appleLanguages: "(en)", appleLocale: "en_US", tagPrefix: "en")
    }

    private func walkSettingsScreens(appleLanguages: String, appleLocale: String, tagPrefix: String) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent", "-AppleLanguages", appleLanguages, "-AppleLocale", appleLocale]
        app.launch()

        XCTAssertTrue(openSettingsFromHamburgerMenu(in: app), "設定シートを開けなかった (\(tagPrefix))")
        // 2: 閉じるボタンはアイコンのみ (xmark) — accessibility identifier は
        // 既存を維持しつつ、`Label`の`.iconOnly`ラベルスタイルで文字
        // "閉じる"/"Close" は表示されない。存在自体とタップ可能性を確認する。
        let closeButton = app.buttons["settingsSheet.closeButton"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 10))
        attachScreenshot(named: "\(tagPrefix)-settings-root-with-xmark-close")

        XCTAssertTrue(navigateToAccountSettingsCategory(in: app), "「アカウントの設定」への遷移に失敗 (\(tagPrefix))")
        XCTAssertTrue(app.switches["settings.cloudSyncToggle"].waitForExistence(timeout: 10))
        attachScreenshot(named: "\(tagPrefix)-account-settings-category")
        goBackToSettingsRoot(in: app)

        XCTAssertTrue(navigateToMailViewerSettingsCategory(in: app), "「メールビューア」への遷移に失敗 (\(tagPrefix))")
        XCTAssertTrue(app.switches["settings.aiFeaturesToggle"].waitForExistence(timeout: 10))
        attachScreenshot(named: "\(tagPrefix)-mail-viewer-settings-category")
        goBackToSettingsRoot(in: app)

        XCTAssertTrue(navigateToMailListSettingsCategory(in: app), "「メール一覧」への遷移に失敗 (\(tagPrefix))")
        // 3: アバター強化バッチ「Google プロフィール写真」トグル・未読のみ
        // 表示 (このカテゴリには無いが、一覧側は別画面) を含む新設トグル群。
        XCTAssertTrue(app.switches["settings.list.showGoogleProfilePhotoToggle"].waitForExistence(timeout: 10))
        attachScreenshot(named: "\(tagPrefix)-mail-list-settings-category")
        goBackToSettingsRoot(in: app)

        XCTAssertTrue(navigateToMailComposeSettingsCategory(in: app), "「メール作成」への遷移に失敗 (\(tagPrefix))")
        XCTAssertTrue(app.buttons["settings.templatesLink"].waitForExistence(timeout: 10))
        attachScreenshot(named: "\(tagPrefix)-mail-compose-settings-category")
        goBackToSettingsRoot(in: app)

        let aboutLink = app.buttons["settings.aboutLink"]
        if aboutLink.waitForExistence(timeout: 5) {
            aboutLink.tap()
            attachScreenshot(named: "\(tagPrefix)-about")
        }
    }

    @discardableResult
    private func goBackToSettingsRoot(in app: XCUIApplication) -> Bool {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        guard backButton.waitForExistence(timeout: 5) else { return false }
        backButton.tap()
        return app.buttons["settings.category.accounts"].waitForExistence(timeout: 5)
    }

    // `MailboxVisibilityView`/`GoogleAvatarDiagnosticsView`(`AccountEditView`
    // から辿る2画面) はここでは screenshot 検証していない —
    // `MailboxVisibilityView`は dev mailstack の Dovecot アカウントが必要、
    // `GoogleAvatarDiagnosticsView`は実際の Gmail OAuth 済みアカウントが
    // 必要で、どちらも自動化コストに見合わないと判断した。この2画面の文言は
    // このファイルで screenshot 確認済みの他画面 (`Text`/`Label`/
    // `NavigationLink`へ文字列リテラルを直接渡す = 自動的にカタログを引く)
    // と全く同じパターンのみで構成されており、`Localizable.xcstrings`への
    // エントリ追加のみで対応できている (Swift側の変更が要る「verbatim」
    // ケースはこの2画面には無かった) — 詳細はタスク#43の作業ログ参照。

    private func attachScreenshot(named name: String) {
        Thread.sleep(forTimeInterval: 1)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
