import XCTest

/// Task #45 実機フィードバック検証:
/// 1. ダークモードで文字が読めない — ライト前提 (白背景 + 濃色文字を明示
///    指定) の HTML メールをダークモード表示中に開くと、暗地に暗文字で
///    ほぼ読めなくなっていた不具合の `HTMLDocumentBuilder`「スマート
///    反転」修正 (`@media (prefers-color-scheme: dark)` の中でのみ
///    `filter: invert(1) hue-rotate(180deg)` を適用)。
/// 2. 本文が途中で切れる — 罫線 (`<hr>`) から下の本文 (段落・CTA ボタン・
///    フッター) が描画されない不具合の `fitToWidthScript` 修正 (画像の
///    `load`/`error` を実際に待ってから高さを計測する)。
///
/// Drives `OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE` (`AppEnvironment.init()`)
/// rather than a real Dovecot account added through the account-setup UI —
/// this simulator/toolchain's account-setup flow has been unreliable
/// against the dev mailstack (`MailCoreErrorDomain error 1`, seen when this
/// test was first written; `docs/verify.md`), and that flag's whole point
/// is to get a real, `bodyState: .fetched` HTML message onto screen via a
/// direct local GRDB insert instead, bypassing IMAP entirely — same escape
/// hatch `OtegamiAvatarDiagnosticsUITests` already established for
/// `OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT`. The injected HTML mirrors
/// `dev/mailstack/seed/fixtures/31-security-notice-dark-mode.eml` (see
/// `AppEnvironment.uitestFakeHTMLMessageBody`'s doc comment for exactly how
/// it differs) — same white-card/dark-text structure, same `<hr>` with two
/// paragraphs + a CTA button below it, same deterministic fit-to-width
/// scale trigger. `OtegamiFitToWidthUITests`/`OtegamiHTMLHeightUITests`と
/// 同じ「合否の実質的なシグナルは目視 (このテスト自身は色までは判定できない
/// — アクセシビリティツリーから文字色/背景色は読めないため)」パターン:
/// このテストが機械的に確認できるのは「罫線より下の本文がアクセシビリティ
/// ツリーに存在するか」(=本文が途中で切れる不具合の直接的な回帰確認)
/// までで、ダークモードの配色そのものはスクリーンショットの目視確認に
/// 委ねる。
final class OtegamiSecurityNoticeDarkModeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSecurityNoticeBodyIsNotTruncatedBelowTheDivider() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE"] = "1"
        app.launch()

        allowNotificationPermissionIfNeeded(timeout: 10)

        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        openMessage(subject: "セキュリティ通知", in: app)

        // 罫線より上 (見出し) — 修正前のバグ品でもここまでは表示される。
        assertBodyContains(text: "アクセスを許可しました", in: app)
        // 罫線より下の本文2段落 — 高さ計測が画像読み込み前に確定して
        // しまう不具合が再発した場合、ここが消える (直接の回帰シグナル)。
        assertBodyContains(text: "第三者が", in: app)
        assertBodyContains(text: "アカウントを保護してください", in: app)
        // さらに下の CTA ボタン・フッター — 罫線直後だけでなく本文全体の
        // 末尾まで欠けていないことの確認 (`OtegamiHTMLHeightUITests`と
        // 同じ「先頭だけでは不十分」という教訓)。
        assertBodyContains(text: "アクティビティを確認", in: app)
        assertBodyContains(text: "配信停止の対象外", in: app)

        // WKWebView がレイアウト/ペイント (fit-to-width の画像待ち含む) を
        // 終える猶予。
        Thread.sleep(forTimeInterval: 3)

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "security-notice-dark-mode"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openMessage(subject: String, in app: XCUIApplication) {
        let list = app.collectionViews["messageList.list"]
        let predicate = NSPredicate(format: "label CONTAINS %@", subject)
        let row = list.cells.containing(predicate).firstMatch
        XCTAssertTrue(waitForElementScrollingIfNeeded(row, in: app), "Expected seeded message \"\(subject)\" to appear in the INBOX list")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
    }

    private func assertBodyContains(text: String, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let element = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "Expected message body to contain \"\(text)\"")
    }
}
