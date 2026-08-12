import XCTest

/// 実機報告 (2026-08-12)「アカウント別グループ表示の行をタップしても
/// 完全に無反応」の再現・再発防止。報告時点の切り分け:
///
/// - 同じ行の**スワイプは効く** → `List` のセルにイベントは届いており、
///   `Button` 側のヒットテストが疑わしい。
/// - Liquid Glass 化 (2026-08-07 `dfed039`) 以降に発生。同じバッチで
///   `AccountDigestRow` は行から背景レイヤーを完全に失った (`ThreadRowView`
///   は `.otegamiCardBackground(.clear, ...)` を残したまま) — FAB で既に
///   踏んだ `020ca83` と同型の疑い。
///
/// `OtegamiSpeedDialFABUITests` と同じ方針で、**行の中心ではなく文字にも
/// アバターにも重ならない位置**を突く — 中心はバグのある実装でも当たって
/// しまい、回帰を検出できない。
final class OtegamiAccountDigestRowTapUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// `scripts/lib/verify-screen-scenarios.sh` の `list-grouped` シナリオと
    /// 同じフィクスチャ構成 — フェイクアカウント2件 (gmail + html) が入り、
    /// `-uitestsOpenAccountDigestDirectly` が `isGroupByAccount` を立てる。
    /// ダイジェスト表示には `accounts.count > 1` が要る
    /// (`AccountDigestPresentation.isVisible`)。
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent", "-uitestsOpenAccountDigestDirectly"]
        app.launchEnvironment["OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT"] = "1"
        app.launchEnvironment["OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE"] = "1"
        app.launchEnvironment["OTEGAMI_UITEST_DISABLE_AVATAR_SOURCES"] = "1"
        app.launchEnvironment["OTEGAMI_UITEST_DISABLE_NOTIFICATION_PERMISSION_REQUEST"] = "1"
        app.launchEnvironment["OTEGAMI_UITEST_DISABLE_CLOUD_SYNC"] = "1"
        return app
    }

    /// 行の identifier は `accountDigest.row.<accountId>` で accountId が
    /// 実行のたびに変わるため前方一致で拾う。`XCUIElementQuery
    /// .matching(NSPredicate)` は Swift 6 で `NSPredicate` が非 `Sendable`
    /// のため使えない (`sending ... risks causing data races`) ので、
    /// 素の走査で絞る — この画面の行はフィクスチャの2件だけなので安い。
    private func digestRows(in query: XCUIElementQuery) -> [XCUIElement] {
        query.allElementsBoundByIndex.filter { $0.identifier.hasPrefix("accountDigest.row.") }
    }

    func testDigestRowTapOffGlyphOpensTheFilteredList() throws {
        let app = makeApp()
        app.launch()

        let list = app.descendants(matching: .any)["accountDigest.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20), "account digest list should be on screen")

        let rowButtons = digestRows(in: app.buttons)
        let anyRows = digestRows(in: app.descendants(matching: .any))

        // アサートより先に「何が見えているか」を記録する — 行が
        // `app.buttons` に出ないなら Button 扱いそのものが壊れており、
        // ヒット領域の話に入る前の問題になる。
        XCTContext.runActivity(named: "digest row element dump") { activity in
            let summary = """
            buttons matching prefix: \(rowButtons.count)
            any elements matching prefix: \(anyRows.count)
            first row (any) frame: \(anyRows.first.map { "\($0.frame)" } ?? "n/a")
            first row (any) isHittable: \(anyRows.first.map { "\($0.isHittable)" } ?? "n/a")
            """
            activity.add(XCTAttachment(string: summary))
            activity.add(XCTAttachment(string: app.debugDescription))
        }

        XCTAssertGreaterThan(
            rowButtons.count, 0,
            "digest rows must be exposed as buttons — falling out of app.buttons means the Button itself stopped being hit-testable"
        )

        let row = try XCTUnwrap(rowButtons.first)
        XCTAssertTrue(row.isHittable, "digest row must be hittable")

        // 行の右寄り・中央高さ — アカウント名/アバター/未読バッジのどの
        // 描画にも重ならない余白。`contentShape` が効いていればここも
        // 行のヒット領域に含まれる。
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()

        let messageList = app.descendants(matching: .any)["messageList.list"]
        XCTAssertTrue(
            messageList.waitForExistence(timeout: 10),
            "tapping a digest row off-glyph must switch to that account's filtered message list"
        )
        XCTAssertTrue(
            list.waitForNonExistence(timeout: 5),
            "the digest list must be replaced once an account is picked"
        )
    }

    /// 実機報告 (2026-08-12) の再現条件そのもの — 同期による継続的な DB
    /// 書き込みが走っている最中に行をタップする
    /// (`UITestSeeder.startDatabaseChurnIfRequested` の doc comment 参照)。
    /// 静止したフィクスチャで緑になる上の2本と違い、こちらが実機の
    /// 「スワイプは効くのにタップだけ無反応」を再現する。
    func testDigestRowTapWorksWhileTheDatabaseKeepsChurning() throws {
        let app = makeApp()
        app.launchEnvironment["OTEGAMI_UITEST_DB_CHURN_MS"] = "150"
        app.launch()

        let list = app.descendants(matching: .any)["accountDigest.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20), "account digest list should be on screen")

        let row = try XCTUnwrap(digestRows(in: app.buttons).first, "digest row should exist")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["messageList.list"].waitForExistence(timeout: 10),
            "a digest row tap must still register while background writes keep the list refreshing"
        )
    }

    /// 上と同じだが、書き込みが `AccountDigest` の中身そのものを変える —
    /// `.removeDuplicates()` (`AccountDigestQuery.digestsObservation`) を
    /// 素通りして `List` の行が更新され続ける状態でのタップ。
    func testDigestRowTapWorksWhileTheListKeepsUpdating() throws {
        let app = makeApp()
        app.launchEnvironment["OTEGAMI_UITEST_DB_CHURN_MS"] = "150"
        app.launchEnvironment["OTEGAMI_UITEST_DB_CHURN_MUTATES"] = "1"
        app.launch()

        let list = app.descendants(matching: .any)["accountDigest.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20), "account digest list should be on screen")

        let row = try XCTUnwrap(digestRows(in: app.buttons).first, "digest row should exist")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["messageList.list"].waitForExistence(timeout: 10),
            "a digest row tap must still register while the rows themselves keep being rebuilt"
        )
    }

    /// 実機報告 (2026-08-13)「アカウント絞り込みチップも、タップして反応は
    /// するが切り替わらない」— 行タップと同じ `accountFilter` を書く経路
    /// なので、同じ画面で並べて固定しておく (`AccountFilterChip` の
    /// `.onTapGesture` 併設の回帰テスト)。
    func testAccountChipTapOpensTheFilteredList() throws {
        let app = makeApp()
        app.launch()

        let list = app.descendants(matching: .any)["accountDigest.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20), "account digest list should be on screen")

        let chips = app.buttons.allElementsBoundByIndex.filter {
            $0.identifier.hasPrefix("mail.chip.") && $0.identifier != "mail.chip.all"
        }
        let chip = try XCTUnwrap(chips.first, "an account filter chip should exist")
        chip.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["messageList.list"].waitForExistence(timeout: 10),
            "tapping an account chip must switch to that account's filtered message list"
        )
        XCTAssertTrue(
            list.waitForNonExistence(timeout: 5),
            "the digest list must be replaced once an account is picked"
        )
    }

    /// スワイプ割り当てを両方 `.pin` にすると `AccountDigestBulkAction.init?`
    /// が nil を返し、そのエッジの `.swipeActions` ブロックが空になる —
    /// 空の `.swipeActions` が行のヒットテストを壊していないことを固定する。
    /// `@AppStorage` は `NSArgumentDomain` 経由で上書きできる。
    func testDigestRowTapStillWorksWhenSwipeActionsResolveToEmpty() throws {
        let app = makeApp()
        app.launchArguments += [
            "-swipeActions.leadingShort", "pin",
            "-swipeActions.leadingLong", "pin",
            "-swipeActions.trailingShort", "pin",
            "-swipeActions.trailingLong", "pin",
        ]
        app.launch()

        let list = app.descendants(matching: .any)["accountDigest.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20), "account digest list should be on screen")

        let row = try XCTUnwrap(digestRows(in: app.buttons).first, "digest row should exist")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["messageList.list"].waitForExistence(timeout: 10),
            "an empty .swipeActions edge must not swallow the row's tap"
        )
    }
}
