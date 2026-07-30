import XCTest

/// 実機フィードバック第2弾 (2026-07-27) の一括目視確認用スクリーンショット
/// テスト。C (カードデザイン)・E (アコーディオン化)・I (設定画面の再構成)
/// を1回の起動でまとめて撮影する — 個別の`scripts/verify-ios-*.sh`を都度
/// 用意する代わりに、このバッチの新規/変更 UI をひとつのテストで通しで
/// 確認する。座標ベースの`.coordinate(...).press(forDuration:)`を`.tap()`
/// より優先しているのは、この simulator/toolchain で`.tap()`が確認済みの
/// `{-1, -1}`ヒットポイント不具合 (`.claude/skills/verify/SKILL.md`のM2節)
/// を避けるため。
final class OtegamiFeedbackBatch2ScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testScreenshotCardListAccordionAndSettingsCategories() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        // アカウントが無ければ追加 (既存インストールに残っていれば no-op) —
        // このプロジェクトで最も実績のあるヘルパー (`addDovecotTest1Account`)
        // をそのまま使う。
        if app.buttons["mail.addAccountButton"].waitForExistence(timeout: 5) {
            try addDovecotTest1Account(in: app)
            restartAppToRecoverTouchDelivery(app)
        }

        // C: カード状一覧 (角丸・輪郭線なし) をスクリーンショット。
        XCTAssertTrue(
            waitForSeededSubjectScrollingIfNeeded("ようこそ otegami へ", in: app),
            "Expected the seeded baseline message in the list"
        )
        Thread.sleep(forTimeInterval: 2)

        // E「アコーディオン化」— Task #33 が2通以上のスレッドの前にスレッド
        // 選択画面を挟むよう変更していた期間もあったが、Task #136 (実機
        // フィードバック「アコーディオンに戻してほしい」) でその選択画面を
        // 廃止し、一覧タップで直接このアコーディオン本文画面へ戻した。2通の
        // 「明日の打ち合わせについて」系スレッドを開き、アコーディオンを
        // ホールドしてスクリーンショット対象にする。
        let threadRow = app.collectionViews["messageList.list"].cells
            .containing(NSPredicate(format: "label CONTAINS %@", "打ち合わせ")).firstMatch
        if threadRow.waitForExistence(timeout: 10) {
            threadRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
            _ = app.scrollViews["threadDetail.scrollView"].waitForExistence(timeout: 10)
            Thread.sleep(forTimeInterval: 2)
            // 深さは一覧→本文の1段のみ — `returnToMailTabRootIfNeeded`は
            // 無害な上位互換なのでそのまま踏襲する。
            returnToMailTabRootIfNeeded(in: app)
        }

        // I: 設定のカテゴリ一覧。
        app.buttons["mail.hamburgerButton"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        let settingsRow = app.buttons["folderSheet.settings"]
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 10))
        settingsRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        XCTAssertTrue(app.otherElements["settingsSheet.navigationStack"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)

        // D: アカウントの設定 → ラベル色ピッカー。
        let accountsCategory = app.buttons["settings.category.accounts"]
        if accountsCategory.waitForExistence(timeout: 5) {
            accountsCategory.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
            let accountRow = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier CONTAINS %@", ".row")).firstMatch
            if accountRow.waitForExistence(timeout: 10) {
                accountRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
                _ = app.buttons["accountEdit.labelColor.auto"].waitForExistence(timeout: 10)
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }
}
