import XCTest

/// アカウントの並び替え — 3 phases (`scripts/verify-ios-account-reorder.sh`),
/// each its own `xcodebuild test -only-testing:` invocation like
/// `OtegamiAccountEditUITests`:
///
///   1. `testDefaultOrderMatchesCreationOrderEverywhere` — add `test1` then
///      `test2`, confirm the default order (no explicit reorder yet) is
///      creation order in every account-order-sensitive surface: 設定の
///      アカウント一覧、ハンバーガーメニューのアカウントセクション、統合トレイの
///      アカウント絞り込みチップ.
///   2. `testDragReorderInSettingsPersists` — enters edit mode (`EditButton`,
///      `settings.accounts.editButton`) and drags `test2`'s row above
///      `test1`'s, then confirms the settings list reflects the new order.
///   3. `testReorderedOrderSurvivesRelaunchAndAppliesEverywhere` — relaunches
///      the app (a fresh process re-reading the same on-disk GRDB database)
///      and confirms the swapped order from phase 2 both persisted and still
///      applies to the hamburger menu and the filter chip row, not just the
///      settings screen that made the change.
///
/// Order is asserted by comparing each row/chip/header's `frame.minY` (or
/// `frame.minX` for the horizontally-scrolling chip row) rather than by
/// index into a `cells`/`buttons` query — this app's settings list has no
/// single `accessibilityIdentifier` on the `List` itself to scope an
/// indexed query to (see `AccountSettingsCategoryView`), and a label-based
/// `CONTAINS` lookup for each account's known display name
/// ("Dovecot Test1"/"Dovecot Test2") is the same robust pattern
/// `.claude/skills/verify/SKILL.md`'s M2/M4/M7 pitfalls already established
/// for this simulator/toolchain (exact-identifier lookups can silently fail
/// on plainly-visible elements; a label predicate doesn't).
final class OtegamiAccountReorderUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDefaultOrderMatchesCreationOrderEverywhere() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)
        addDovecotTest2Account(in: app)

        openAccountSettingsCategory(in: app)
        let (test1SettingsY, test2SettingsY) = accountRowYPositions(in: app)
        XCTAssertLessThan(test1SettingsY, test2SettingsY, "既定の並び順は作成順 (test1 が test2 より上) のはず")
        closeSettingsSheet(in: app)

        openHamburgerMenuIfNeeded(in: app)
        let (test1HeaderY, test2HeaderY) = accountHeaderYPositions(in: app)
        XCTAssertLessThan(test1HeaderY, test2HeaderY, "ハンバーガーメニューの既定の並び順も作成順のはず")
        app.buttons["folderSheet.closeButton"].tap()

        let (test1ChipX, test2ChipX) = accountChipXPositions(in: app)
        XCTAssertLessThan(test1ChipX, test2ChipX, "アカウント絞り込みチップの既定の並び順も作成順のはず")

        Thread.sleep(forTimeInterval: 4)
    }

    func testDragReorderInSettingsPersists() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        openAccountSettingsCategory(in: app)
        let (test1Before, test2Before) = accountRowYPositions(in: app)
        XCTAssertLessThan(test1Before, test2Before, "並び替え前は phase 1 が確認した作成順のままのはず")

        let editButton = app.buttons["settings.accounts.editButton"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 5), "並び替え用の Edit ボタンが見つからない")
        editButton.tap()

        // test2 の行 (下) を test1 の行 (上) より上へドラッグする — 行の末尾
        // (並び替えハンドルが出る位置) を掴んで、移動先の行の上端寄りへ
        // ドロップする。
        let test2Row = accountRow(labelContains: "Dovecot Test2", in: app)
        let test1Row = accountRow(labelContains: "Dovecot Test1", in: app)
        XCTAssertTrue(test2Row.exists && test1Row.exists, "並び替え対象の行が編集モードで見つからない")
        let dragStart = test2Row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        let dragEnd = test1Row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.1))
        dragStart.press(forDuration: 0.6, thenDragTo: dragEnd)

        // 編集モードを抜ける (同じボタン、ラベルが「完了」に変わる).
        editButton.tap()

        let (test1After, test2After) = accountRowYPositions(in: app)
        XCTAssertLessThan(test2After, test1After, "ドラッグ後は test2 が test1 より上に来るはず")

        Thread.sleep(forTimeInterval: 4)
    }

    func testReorderedOrderSurvivesRelaunchAndAppliesEverywhere() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        openAccountSettingsCategory(in: app)
        let (test1SettingsY, test2SettingsY) = accountRowYPositions(in: app)
        XCTAssertLessThan(test2SettingsY, test1SettingsY, "再起動後も設定のアカウント一覧は phase 2 で並び替えた順のはず")
        closeSettingsSheet(in: app)

        openHamburgerMenuIfNeeded(in: app)
        let (test1HeaderY, test2HeaderY) = accountHeaderYPositions(in: app)
        XCTAssertLessThan(test2HeaderY, test1HeaderY, "ハンバーガーメニューにも並び替え後の順序が反映されるはず")
        app.buttons["folderSheet.closeButton"].tap()

        let (test1ChipX, test2ChipX) = accountChipXPositions(in: app)
        XCTAssertLessThan(test2ChipX, test1ChipX, "アカウント絞り込みチップにも並び替え後の順序が反映されるはず")

        Thread.sleep(forTimeInterval: 4)
    }

    // MARK: - Helpers

    private func openAccountSettingsCategory(in app: XCUIApplication) {
        openSettingsFromHamburgerMenu(in: app)
        XCTAssertTrue(navigateToAccountSettingsCategory(in: app), "「アカウントの設定」カテゴリへの遷移に失敗した")
    }

    /// `mail.hamburgerButton`をタップしてハンバーガーメニューを開く。既に開いて
    /// いる (`folderSheet.list`が既に存在する) 場合は何もしない — 呼び出し側が
    /// 直前にどの画面にいたかに依存しないようにするための軽いガード。
    private func openHamburgerMenuIfNeeded(in app: XCUIApplication) {
        guard !app.collectionViews["folderSheet.list"].exists else { return }
        app.buttons["mail.hamburgerButton"].tap()
        XCTAssertTrue(app.collectionViews["folderSheet.list"].waitForExistence(timeout: 10), "ハンバーガーメニューが開かなかった")
    }

    /// 設定のアカウント一覧内、指定した表示名を含む行そのもの (ドラッグの
    /// 起点/終点として使う) — `.row`サフィックス付きの識別子と、行内の
    /// テキストに`displayNameSubstring`を含むことの両方で絞り込む
    /// (`OtegamiAccountEditUITests.openAccountEditScreen`と同じ理由で`.any`
    /// マッチ: `NavigationLink`行の公開されるアクセシビリティ型は`.button`
    /// とは限らない)。
    private func accountRow(labelContains displayNameSubstring: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@ AND label CONTAINS %@", ".row", displayNameSubstring))
            .firstMatch
    }

    /// (test1 の Y 座標, test2 の Y 座標) — 設定のアカウント一覧の現在の並び順を
    /// 読み取る。値そのものではなく大小関係だけを呼び出し側が見る。
    private func accountRowYPositions(in app: XCUIApplication) -> (test1: CGFloat, test2: CGFloat) {
        let test1 = accountRow(labelContains: "Dovecot Test1", in: app)
        let test2 = accountRow(labelContains: "Dovecot Test2", in: app)
        XCTAssertTrue(test1.waitForExistence(timeout: 10), "設定のアカウント一覧に test1 が見つからない")
        XCTAssertTrue(test2.waitForExistence(timeout: 10), "設定のアカウント一覧に test2 が見つからない")
        return (test1.frame.minY, test2.frame.minY)
    }

    /// (test1 セクションヘッダの Y 座標, test2 セクションヘッダの Y 座標) —
    /// ハンバーガーメニュー (`FolderListSheet`) のアカウントセクション見出し
    /// (`AccountSectionHeader`) の現在の並び順を読み取る。
    private func accountHeaderYPositions(in app: XCUIApplication) -> (test1: CGFloat, test2: CGFloat) {
        let test1 = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@ AND label CONTAINS %@", "folderSheet.account.", "Dovecot Test1"))
            .firstMatch
        let test2 = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@ AND label CONTAINS %@", "folderSheet.account.", "Dovecot Test2"))
            .firstMatch
        XCTAssertTrue(test1.waitForExistence(timeout: 10), "ハンバーガーメニューに test1 のセクションが見つからない")
        XCTAssertTrue(test2.waitForExistence(timeout: 10), "ハンバーガーメニューに test2 のセクションが見つからない")
        return (test1.frame.minY, test2.frame.minY)
    }

    /// (test1 チップの X 座標, test2 チップの X 座標) — 統合トレイのアカウント
    /// 絞り込みチップ行 (`mail.chipRow`) の現在の並び順を読み取る。
    private func accountChipXPositions(in app: XCUIApplication) -> (test1: CGFloat, test2: CGFloat) {
        let chipRow = app.scrollViews["mail.chipRow"]
        XCTAssertTrue(chipRow.waitForExistence(timeout: 10), "アカウント絞り込みチップ行が見つからない")
        let test1 = chipRow.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Dovecot Test1"))
            .firstMatch
        let test2 = chipRow.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Dovecot Test2"))
            .firstMatch
        XCTAssertTrue(test1.waitForExistence(timeout: 10), "チップ行に test1 が見つからない")
        XCTAssertTrue(test2.waitForExistence(timeout: 10), "チップ行に test2 が見つからない")
        return (test1.frame.minX, test2.frame.minX)
    }
}
