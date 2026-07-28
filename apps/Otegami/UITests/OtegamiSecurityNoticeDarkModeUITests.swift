import XCTest

/// Task #45 実機フィードバック検証、および Task #51 でのその退行修正:
/// 1. ダークモードで文字が読めない — ライト前提 (白背景 + 濃色文字を明示
///    指定) の HTML メールをダークモード表示中に開くと、暗地に暗文字で
///    ほぼ読めなくなっていた不具合の `HTMLDocumentBuilder`「スマート
///    反転」修正 (`@media (prefers-color-scheme: dark)` の中でのみ
///    `filter: invert(1) hue-rotate(180deg)` を適用)。
/// 2. 本文が途中で切れる — 罫線 (`<hr>`) から下の本文 (段落・CTA ボタン・
///    フッター) が描画されない不具合の `fitToWidthScript` 修正 (画像の
///    `load`/`error` を実際に待ってから高さを計測する)。
/// 3. (Task #51) 1 の修正が「メールが自前のダーク対応を持たなければ常に
///    反転」という条件のままだったため、色指定を一切持たないメールまで
///    反転してしまい、元々正しく読めていたはずの文字が暗地に暗文字へ
///    壊れる退行があった。`HTMLWebViewCoordinator.fitToWidthScript`が
///    画像読み込み完了後に実効背景色を実測し、実際にライト配色だと
///    判定できた場合だけ反転するよう修正 — このファイルはその3ケースを
///    それぞれ開いてスクリーンショットする。
///
/// Task #56 (TestFlight風の通知メールの実機フィードバック、4点セット):
/// 4つ目のテストメソッド (`testBetaTestingNoticeRendersFullyWithoutOverlap`)
/// はこの3ケースとは別枠 — 画像の巨大化禁止 (`img`向けCSSの`:not()`
/// スコープ修正)、背景なし+濃色文字の可読化 (`decideDarkInversion`の
/// 「背景が解決しない」分岐拡張)、高さ切れの再確認、要約/翻訳フローティング
/// ボタンの本文被り解消 (`HTMLMessageView.bottomContentInset`) の4点を
/// まとめて検証する。`docs/design-system.md`のTask #56節に詳細。
///
/// Drives `OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE` (`AppEnvironment.init()`)
/// rather than a real Dovecot account added through the account-setup UI —
/// this simulator/toolchain's account-setup flow has been unreliable
/// against the dev mailstack (`MailCoreErrorDomain error 1`, seen when this
/// test was first written; `docs/verify.md`), and that flag's whole point
/// is to get real, `bodyState: .fetched` HTML messages onto screen via a
/// direct local GRDB insert instead, bypassing IMAP entirely — same escape
/// hatch `OtegamiAvatarDiagnosticsUITests` already established for
/// `OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT`. `AppEnvironment
/// .uitestFakeHTMLMessages` now seeds six messages (see that array's doc
/// comment) mirroring the regression cases above — this test opens each of
/// the first four in turn. (The 5th, MakerWorld比較 — 実機フィードバック, is
/// exercised via `scripts/verify-screen.sh html-4`, and the 6th (Task #98,
/// Google カレンダー招待メール風、実機フィードバック) via
/// `scripts/verify-screen.sh html-5` — neither has its own XCTest method
/// here, since their point is a dark-mode color-rendering comparison — the
/// same "目視確認に委ねる" category the rest of this doc comment already
/// describes, not a new accessibility-tree assertion.)
///
/// **既知の環境問題 (Task #51 のスコープ外)**: この検証中に、
/// `messageList.list` の行を XCUITest から実際にタップしても本文詳細へ
/// 遷移しないことがある不具合を確認した — `git stash`して確かめた通り
/// `origin/main`をこのタスクの変更を一切当てずにそのまま動かしても同じ
/// 症状が再現するため、Task #51 のどの変更とも無関係の既存の不具合
/// (`MessageListRow`の`.highPriorityGesture(swipeGesture)`がタップ自体を
/// 飲み込んでいる可能性が高い)。このファイルではその不具合を修正せず、
/// `openMessage(subject:in:)`にリトライと実在確認 (後述) を持たせることで
/// 実際のタップ経路を検証しつつ現実的な範囲で耐性を上げるに留めた。
/// `OtegamiFitToWidthUITests`/`OtegamiHTMLHeightUITests`と同じ「合否の
/// 実質的なシグナルは目視 (このテスト自身は色までは判定できない —
/// アクセシビリティツリーから文字色/背景色は読めないため)」パターン:
/// このテストが機械的に確認できるのは「本文がアクセシビリティツリーに
/// 存在するか」(=本文が途中で切れる不具合の直接的な回帰確認) までで、
/// ダークモードの配色そのものはスクリーンショットの目視確認に委ねる
/// (シミュレータの外観切り替えは `xcrun simctl ui booted appearance dark`
/// — このテスト自身はシミュレータの現在の外観設定のまま撮影するだけで、
/// 外観そのものは切り替えない)。
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

        screenshotCurrentScreen(named: "security-notice-dark-mode", in: app)
    }

    /// Task #51 の退行ケース (case a): 色指定を一切持たないメール。反転が
    /// 誤ってかかっていないかはスクリーンショットの目視でのみ確認できる
    /// が、罫線を持たないシンプルな構造なので本文全体がそのまま存在する
    /// ことだけは機械的に確認しておく。
    func testPlainMessageWithNoColorsIsNotTruncated() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE"] = "1"
        app.launch()

        allowNotificationPermissionIfNeeded(timeout: 10)

        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        openMessage(subject: "色指定なしのシンプルなお知らせ", in: app)

        assertBodyContains(text: "背景色・文字色のどちらも一切指定していません", in: app)
        assertBodyContains(text: "その再現ケース", in: app)

        screenshotCurrentScreen(named: "plain-html-no-colors-dark-mode", in: app)
    }

    /// Task #51 の回帰確認 (case c): メールが自前で `prefers-color-scheme`
    /// を宣言している場合は、`HTMLDocumentBuilder`が反転を検討すること
    /// 自体をそもそもしない (`shouldConsiderDarkInversion` が false) —
    /// ライト・ダークどちらの外観でもこのメール自身の配色のまま表示される
    /// はず、という期待をスクリーンショットで確認する。
    func testSelfDarkAwareMessageIsNeverInverted() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE"] = "1"
        app.launch()

        allowNotificationPermissionIfNeeded(timeout: 10)

        XCTAssertTrue(app.collectionViews["messageList.list"].waitForExistence(timeout: 15))

        openMessage(subject: "自前ダーク対応済みのお知らせ", in: app)

        assertBodyContains(text: "prefers-color-scheme で自前のダークモード対応を宣言しています", in: app)

        screenshotCurrentScreen(named: "self-dark-aware-message", in: app)
    }

    /// Task #56 検証用 (実機フィードバック: TestFlight風の通知メールで
    /// 「1. 画像の巨大化」「2. 背景なし+濃色文字が読めない」「3. 高さ切れ」
    /// 「4. 要約/翻訳フローティングボタンが本文に被る」の4点が同時発生)。
    /// このテスト自身が機械的に確認できるのは (a) 罫線を持たない代わりに
    /// 複数段落あるぶん本文が最後の段落まで欠けずに描画されていること
    /// (3の直接の回帰シグナル)、(b) `assertBodyContains`が拾える最後の
    /// フッター行の存在 — 1 (画像サイズ)・2 (文字色反転)・4 (ボタン被り)
    /// はいずれもアクセシビリティツリーだけでは判定できない見た目の問題
    /// なので、スクリーンショットの目視確認に委ねる (このファイルの他の
    /// テストメソッドと同じパターン)。
    func testBetaTestingNoticeRendersFullyWithoutOverlap() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE"] = "1"
        // Task #56: この4件セットの検証を書いている最中、この既存ファイルの
        // 他3メソッド (このコミット以前から存在し、このバッチの変更を一切
        // 受けていない) でも `messageList.list` の行タップが同じように
        // `htmlWebView never appeared` で失敗することを確認した — この
        // シミュレータ/ツールチェーン固有の既知の環境問題 (このファイル冒頭
        // のdoc comment) であって、Task #56 のどの変更が原因でもない。
        // `AppEnvironment.uitestDirectOpenThreadId`
        // (`OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX`) の直接遷移経路で
        // タップそのものを迂回する — 3 (betaTestingNotice は
        // `uitestFakeHTMLMessages`の0始まりインデックスで3番目)。
        app.launchEnvironment["OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX"] = "3"
        app.launch()

        // Task #56: `openMessage(subject:in:)` (the other 3 tests in this
        // file) already calls `dismissContactsPermissionPromptIfNeeded`
        // before every row-press attempt — this test skips `openMessage`
        // entirely (the direct-open path above), so it has to dismiss
        // system permission prompts itself instead. Confirmed necessary on
        // a freshly-erased/uninstalled simulator install, and confirmed
        // *not* reliably resolved by a single upfront pass of each: the
        // notifications prompt (`BadgeCenter.requestAuthorizationIfNeeded()`)
        // can fire noticeably later than the contacts one (triggered by
        // avatar resolution once the seeded message renders), so either can
        // still be sitting on screen — starving every subsequent
        // `waitForExistence` poll — after a single early call to each
        // already returned. Looping both a few times, spaced out, catches
        // whichever shows up whenever it shows up without needing to know
        // the exact order.
        for _ in 0..<4 {
            allowNotificationPermissionIfNeeded(timeout: 2)
            dismissContactsPermissionPromptIfNeeded(timeout: 2)
        }

        XCTAssertTrue(waitForMessageDetailToAppear(in: app, timeout: 20), "Expected the Task #56 direct-open path to land on the message detail view (htmlWebView never appeared)")

        // 冒頭 — 修正前のバグ品でもここまでは表示される。
        assertBodyContains(text: "AppSample 2.1", in: app)
        // 中盤の段落群 — 高さ計測が画像読み込み前に確定してしまう不具合
        // (3) が再発した場合、ここから下が消える。
        assertBodyContains(text: "Otegami Beta app", in: app)
        assertBodyContains(text: "contact the developer", in: app)
        // 末尾のフッター行 — 本文全体の最後まで欠けていないことの確認。
        assertBodyContains(text: "beta.otegami.test", in: app)

        screenshotCurrentScreen(named: "beta-testing-notice", in: app)
    }

    /// WKWebView がレイアウト/ペイント (fit-to-width の画像待ち・Task #51
    /// の実測による invert 判定含む) を終える猶予を置いてから撮影する —
    /// 3つのテストメソッドすべてが同じ手順を踏むための共通ヘルパー。
    private func screenshotCurrentScreen(named name: String, in app: XCUIApplication) {
        Thread.sleep(forTimeInterval: 3)

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openMessage(subject: String, in app: XCUIApplication) {
        let list = app.collectionViews["messageList.list"]
        let predicate = NSPredicate(format: "label CONTAINS %@", subject)
        let row = list.cells.containing(predicate).firstMatch
        // Task #51: re-runs `waitForElementScrollingIfNeeded` (not just
        // once, up front) on every attempt below, and presses only once
        // it's confirmed present again right before the press — three
        // messages (up from one) sharing the same sender means three rows'
        // worth of async avatar/sender-lookup-driven re-rendering can land
        // around the same time, and a row this app-level query resolves
        // one moment can genuinely be gone from the next accessibility
        // snapshot XCTest takes a few hundred ms later. Giving
        // `dismissContactsPermissionPromptIfNeeded` a chance to fire
        // *before* re-confirming the row (rather than only before the
        // press) means a permission-prompt-triggered re-render has already
        // happened by the time presence is checked, instead of racing it.
        // Note: even with this retry, opening a row can still fail to
        // navigate on this project's current simulator/toolchain — see
        // this file's own doc comment ("既知の環境問題") for why that's a
        // separate, pre-existing issue this test can't itself fix.
        for attempt in 0..<3 {
            dismissContactsPermissionPromptIfNeeded(timeout: attempt == 0 ? 2 : 0.5)
            guard waitForElementScrollingIfNeeded(row, in: app) else { continue }
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
            if waitForMessageDetailToAppear(in: app, timeout: 8) { return }
        }
        XCTFail("Expected tapping \"\(subject)\" to open the message detail view (htmlWebView never appeared)")
    }

    /// Task #51: confirms *real* navigation into `HTMLMessageView` (its
    /// `messageDetail.htmlWebView` identifier) rather than trusting a
    /// generic `assertBodyContains` call, which can otherwise pass
    /// spuriously — `MessageListRow`'s own preview snippet on
    /// `messageList.list` can coincidentally contain the same substring
    /// being asserted (this app deliberately seeds each fake message's
    /// `snippet` from its own first body paragraph), so a body-text
    /// assertion alone can't distinguish "genuinely opened the message"
    /// from "still sitting on the list, tap silently didn't land."
    private func waitForMessageDetailToAppear(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let webView = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier CONTAINS %@", "messageDetail.htmlWebView")
        ).firstMatch
        return webView.waitForExistence(timeout: timeout)
    }

    private func assertBodyContains(text: String, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let element = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "Expected message body to contain \"\(text)\"")
    }
}
