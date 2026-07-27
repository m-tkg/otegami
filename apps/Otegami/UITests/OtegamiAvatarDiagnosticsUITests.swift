import XCTest

/// Task #42「アバター診断」: 実 Google 認証を伴わずに
/// `GoogleAvatarDiagnosticsView`が表示崩れなく描画されることだけを確認する
/// 軽量 UITest。`OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT`
/// (`AppEnvironment.init()`) が挿入する、実トークンを持たない偽の
/// `.gmail`アカウントへ遷移する — スコープ診断・索引の強制再構築は
/// いずれもネットワーク到達不能/リフレッシュトークン喪失と同じ経路で
/// 失敗し、"確認できませんでした"/"取得失敗" 系の表示に倒れる
/// (`AppEnvironment.googleGrantedScope(for:)`/`googleAvatarDiagnostics(for:)`
/// のドキュメントコメント参照)。これはこのテストの目的そのもの —
/// 実際の診断結果ではなく、画面のレイアウトが崩れないことだけを検証する。
final class OtegamiAvatarDiagnosticsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAvatarDiagnosticsScreenRendersWithoutLayoutBreakage() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launchEnvironment["OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT"] = "1"
        app.launch()
        // M9's notification-permission prompt (`allowNotificationPermissionIfNeeded`'s
        // doc comment) can otherwise steal the very first synthesized tap
        // below on a freshly-erased simulator's first launch.
        _ = allowNotificationPermissionIfNeeded(timeout: 5)

        XCTAssertTrue(openSettingsFromHamburgerMenu(in: app), "Failed to open settings from hamburger menu")
        XCTAssertTrue(navigateToAccountSettingsCategory(in: app), "Failed to navigate to accounts settings category")

        let accountRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "settings.account.", ".row")
        ).firstMatch
        XCTAssertTrue(accountRow.waitForExistence(timeout: 10), "Fake Gmail account row not found")
        accountRow.tap()

        XCTAssertTrue(app.otherElements["accountEdit.screen"].waitForExistence(timeout: 10) || app.collectionViews["accountEdit.screen"].waitForExistence(timeout: 10), "AccountEditView did not appear")

        // `AccountEditView`'s Gmail「認証」section (and its「アバター診断」
        // link) sits well below the fold — `Form`/`List` on iOS is a
        // `UICollectionView` with cell reuse, so a row this far down isn't
        // necessarily materialized (or accessibility-addressable) until
        // scrolled near the viewport (the `LazyVStack` analog documented
        // in this skill's M4 section). Scroll down a few times before
        // giving up.
        let diagnosticsLink = app.buttons["accountEdit.avatarDiagnosticsLink"]
        let accountEditScrollable = app.collectionViews["accountEdit.screen"]
        for _ in 0..<6 where !diagnosticsLink.exists {
            accountEditScrollable.swipeUp()
        }
        XCTAssertTrue(diagnosticsLink.waitForExistence(timeout: 10), "アバター診断 link not found on a .gmail account's edit screen")
        diagnosticsLink.tap()

        let diagnosticsScreen = app.otherElements["googleAvatarDiagnostics.screen"]
        let diagnosticsScreenAsList = app.collectionViews["googleAvatarDiagnostics.screen"]
        XCTAssertTrue(diagnosticsScreen.waitForExistence(timeout: 10) || diagnosticsScreenAsList.waitForExistence(timeout: 10), "GoogleAvatarDiagnosticsView did not appear")

        // No real token exists for the fake account, so every network call
        // fails fast — give the `.task` a moment to settle into its final
        // (failure) state before checking anything below. Checked near the
        // top of the `Form` (this state's own section, right under
        // "スコープ") *before* scrolling down for the refresh button below
        // — once scrolled past, `UICollectionView` cell reuse can drop an
        // off-screen row from the accessibility tree entirely, unlike a
        // plain view hierarchy (this skill's own notes on `List`-backed
        // `Form`s apply here too).
        let scopeUnknown = app.descendants(matching: .any)["accountEdit.scopeDiagnosis.unknown"]
        let tokenFetchFailed = app.descendants(matching: .any)["googleAvatarDiagnostics.tokenFetchFailed"]
        XCTAssertTrue(
            scopeUnknown.waitForExistence(timeout: 15) || tokenFetchFailed.waitForExistence(timeout: 15),
            "Expected either the scope-unknown or token-fetch-failed state for an account with no real refresh token"
        )

        // Same below-the-fold scrolling as `accountEdit.screen` above —
        // this `Form` has several sections (scope, 3 per-source rows, index
        // summary) before the "もう一度診断する" button's section.
        let refreshButton = app.buttons["googleAvatarDiagnostics.refreshButton"]
        let diagnosticsScrollable = diagnosticsScreenAsList.exists ? diagnosticsScreenAsList : diagnosticsScreen
        for _ in 0..<8 where !refreshButton.exists {
            diagnosticsScrollable.swipeUp()
        }
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 15), "「もう一度診断する」button not found — screen may have failed to lay out")
    }
}
