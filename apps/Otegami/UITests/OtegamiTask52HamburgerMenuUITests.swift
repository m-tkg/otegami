import XCTest

/// Task #52 の3点 (ハンバーガーメニューの改善) を実機シミュレータで確認する
/// ための UITest — `.claude/skills/verify/
/// SKILL.md`の M6 節と同じ「非永続 UI (メニューの開閉状態など) はテスト側で
/// `Thread.sleep`して画面を保持し、ホスト側シェルが並行してスクリーンショット
/// を撮る」パターンを使う。`OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT`
/// (`AppEnvironment.swift`) が Task #52 でこのテストのために拡張され、
/// INBOX/All Mail/Sent Mail と「本当にアーカイブ済み」「まだ受信トレイに
/// ある (未アーカイブ)」の2スレッドを注入するようになった。
///
/// **`Thread.sleep`は要素の解決とアクション (タップ/ドラッグ) の間に絶対に
/// 挟まないこと** — 実機シミュレータで、フェイクメッセージの送信者
/// ("qa@example.com") をアバター解決が連絡先と突き合わせようとして初回起動
/// 時に「連絡先へのアクセスを許可しますか」の実システムダイアログが出る
/// ことを確認した。`Thread.sleep`中にこれが前面に出ると、座標ベースの
/// タップ/ドラッグがそのシステムシートに当たってしまい本来の行に届かない
/// (`xcodebuild test`のログは「Synthesize event」が成功したと報告するが、
/// 実際にはアプリの状態が一切変わらない、という分かりにくい失敗になる)。
/// このファイルの各テストは「要素を解決→即アクション」を徹底し、
/// スクリーンショット用の`Thread.sleep`は要素解決/アクションを一切挟まない
/// 場所 (アクションの直後、次の解決の前) にだけ置く。念のため
/// `xcrun simctl privacy grant contacts com.mtkg.otegami`を検証前に実行して
/// ダイアログ自体が出ないようにもしている。
final class OtegamiTask52HamburgerMenuUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 1: カテゴリ配下の行がアカウント名+色バーになっていること。
    /// 2: Gmail (All Mail) がアーカイブカテゴリに出て、かつ「本当にアーカイブ
    /// 済み」のメッセージだけを表示する (INBOX にも残っているメッセージの
    /// 写しは出ない) こと。この2つを1テストにまとめている — どちらも同じ
    /// フェイク Gmail アカウント1つの状態を見るだけで確認できるため。
    func testCategoryAccountRowsAndGmailArchiveMapping() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT"] = "1"
        app.launch()

        app.buttons["mail.hamburgerButton"].tap()
        XCTAssertTrue(app.collectionViews["folderSheet.list"].waitForExistence(timeout: 10), "ハンバーガーメニューが開かなかった")

        // 概観のスクリーンショット用に画面を保持する (要素解決の前 — 上の
        // doc comment参照)。カテゴリ群 (上) →アカウント群 (下) の両方が
        // 同時に見えているはず (旧セグメント切替の廃止、Task #52 追記)。
        Thread.sleep(forTimeInterval: 5)

        let archiveHeader = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "folderSheet.category.archive.header"))
            .firstMatch
        XCTAssertTrue(archiveHeader.waitForExistence(timeout: 10), "「アーカイブ」カテゴリセクションが見つからない")
        let accountTreeHeader = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@ AND label CONTAINS %@", "folderSheet.account.", "Fake Gmail"))
            .firstMatch
        XCTAssertTrue(accountTreeHeader.waitForExistence(timeout: 10), "アカウント群のセクション (Fake Gmail のフォルダツリー) が見つからない")

        // 「アーカイブ」カテゴリ配下の Gmail の行 — アカウント名 (フォルダ
        // パスではない) が表示されているはず。mailboxPath 由来の識別子接尾辞
        // ("All Mail") で、同じアカウント名が並ぶ他カテゴリ (受信トレイ/送信
        // 済み) の行と区別する。解決したら即タップする (doc comment参照)。
        let archiveGmailRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@ AND identifier CONTAINS %@", "folderSheet.category.account.", "All Mail"))
            .firstMatch
        XCTAssertTrue(archiveGmailRow.waitForExistence(timeout: 10), "アーカイブカテゴリ配下に Gmail (All Mail マッピング) の行が見つからない")
        XCTAssertTrue(archiveGmailRow.label.contains("Fake Gmail"), "アーカイブ配下の行はメールボックス名ではなくアカウント名を表示すべき — label=\(archiveGmailRow.label)")
        archiveGmailRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        // タップして開いた一覧で、「アーカイブ済み」の1通だけが見えることを
        // 確認する (「受信トレイのメール」= INBOX と重複する未アーカイブの
        // 写しは GmailArchiveFilter により除外されるはず)。
        let list = app.collectionViews["messageList.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "アーカイブ行タップ後、メッセージ一覧が開かなかった")
        let archivedRow = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "アーカイブ済みメール"))
        XCTAssertTrue(archivedRow.firstMatch.waitForExistence(timeout: 10), "本当にアーカイブ済みのメールが一覧に出ていない")
        let unarchivedRow = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "受信トレイのメール"))
        XCTAssertFalse(unarchivedRow.firstMatch.exists, "INBOX にも残っている (未アーカイブの) メールがアーカイブ一覧に出てしまっている")

        // 一覧のスクリーンショット用に画面を保持する (最後 — この後に要素
        // 解決/アクションは無い)。
        Thread.sleep(forTimeInterval: 5)
    }

    /// 3-a: 設定画面でカテゴリを並び替えられること。`testCategoryReorder
    /// AppliesToHamburgerMenu`が次のフェーズとして続き、これが書き込んだ
    /// 順序 (`FolderCategoryOrderStore`、`UserDefaults`永続化) を新しい
    /// `app.launch()`で読み直して検証する — `OtegamiAccountReorderUITests`
    /// と同じ「フェーズごとに別の`app.launch()`」構成 (同じ`xcodebuild test`
    /// 実行内でシミュレータの GRDB/`UserDefaults`状態は launch を跨いで
    /// 持続する)。1つの launch 内で設定シートを閉じてハンバーガーメニューを
    /// 開き直す一発勝負の検証は、ドラッグ直後の`List`編集モードの後始末
    /// (アニメーション/ツールバー状態) と絡んで不安定だったため、フェーズを
    /// 分けた。
    func testCategoryReorderInSettings() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT"] = "1"
        app.launch()

        XCTAssertTrue(openSettingsFromHamburgerMenu(in: app), "設定シートが開かなかった")
        XCTAssertTrue(navigateToMailListSettingsCategory(in: app), "「メール一覧」設定カテゴリへの遷移に失敗した")

        // 「メール一覧」設定カテゴリは項目数が多く、「カテゴリの並び替え」
        // リンクは画面の少し下 — `List`の仮想化で未描画のことがある
        // (`.claude/skills/verify/SKILL.md`のM4節「LazyVStack」と同種の
        // 事象)。念のため軽くスクロールしてから探す。
        app.swipeUp()

        // `.claude/skills/verify/SKILL.md`のM2節 (パターン4): 完全一致の
        // identifier subscript ルックアップが、画面に見えている要素に対して
        // even失敗することがあるこの simulator/toolchain の既知の挙動 — 念の
        // ため`CONTAINS`述語で引く。
        let categoryOrderLink = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "settings.list.categoryOrderLink"))
            .firstMatch
        XCTAssertTrue(categoryOrderLink.waitForExistence(timeout: 10), "「カテゴリの並び替え」へのリンクが見つからない")
        categoryOrderLink.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        let reorderList = app.collectionViews["folderCategoryOrderSettings.list"]
        XCTAssertTrue(reorderList.waitForExistence(timeout: 10), "カテゴリ並び替え画面が開かなかった")

        // 並び替え前のスクリーンショット用に画面を保持する (要素解決の前)。
        Thread.sleep(forTimeInterval: 4)

        // 既定順は「受信トレイ」が先頭 — 「アーカイブ」の行を先頭までドラッグ
        // する。解決したら即ドラッグする (クラス doc comment参照)。
        let inboxRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "folderCategoryOrderSettings.row.inbox"))
            .firstMatch
        let archiveRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "folderCategoryOrderSettings.row.archive"))
            .firstMatch
        XCTAssertTrue(inboxRow.waitForExistence(timeout: 10) && archiveRow.waitForExistence(timeout: 10), "並び替え対象の行が見つからない")
        let dragStart = archiveRow.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        let dragEnd = inboxRow.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.1))
        dragStart.press(forDuration: 0.6, thenDragTo: dragEnd)

        // 並び替え後のスクリーンショット用に画面を保持する (最後 — この後に
        // 要素解決/アクションは無い。ドラッグの反映アニメーションが落ち着く
        // 時間も兼ねる)。
        Thread.sleep(forTimeInterval: 5)
    }

    /// 3-b: 並び替えた順序がハンバーガーメニューに反映されていること —
    /// `testCategoryReorderInSettings`が書き込んだ`FolderCategoryOrderStore`
    /// の永続値を、新しい`app.launch()`で読み直して確認する。
    func testCategoryReorderAppliesToHamburgerMenu() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT"] = "1"
        app.launch()

        app.buttons["mail.hamburgerButton"].tap()
        XCTAssertTrue(app.collectionViews["folderSheet.list"].waitForExistence(timeout: 10), "ハンバーガーメニューが開かなかった")

        let archiveHeader = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "folderSheet.category.archive.header"))
            .firstMatch
        let inboxHeader = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "folderSheet.category.inbox.header"))
            .firstMatch
        XCTAssertTrue(archiveHeader.waitForExistence(timeout: 10) && inboxHeader.waitForExistence(timeout: 10), "カテゴリ見出しが見つからない")
        XCTAssertLessThan(
            archiveHeader.frame.minY, inboxHeader.frame.minY,
            "並び替え設定で「アーカイブ」を「受信トレイ」より上に動かしたのに、メニューに反映されていない"
        )

        // スクリーンショット用に画面を保持する (最後)。
        Thread.sleep(forTimeInterval: 5)
    }
}
