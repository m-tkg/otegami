import XCTest

/// M4 verification, phase 1: add the Dovecot `test1` account (same as
/// M1/M3's setup), confirm the pre-M4 baseline subjects still render, and
/// confirm M4's headline behavior — a References-linked multi-message
/// conversation collapses into a single thread row with a message-count
/// badge (plan checkpoint (a): "往復メールが 1 スレッド"). Uses the
/// `09/10/11-thread-b-*.eml` seed fixtures (a 3-message test1<->test2
/// References chain, all delivered into test1's INBOX) rather than
/// 02/03 (which is only 2 messages) so the badge count itself
/// (unambiguously "3", not "2" which could also just mean "1 unread + 1
/// read" in a differently-designed badge) is a strong signal threading
/// actually ran.
final class OtegamiM4SetupUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddAccountAndThreadedBaselineAppears() throws {
        let app = XCUIApplication()
        app.launch()

        addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)

        // Pre-M4 baseline: unthreaded singleton messages still show their
        // own subject as a degenerate one-message "thread" row.
        for subject in ["ようこそ otegami へ", "Ｆｗｄ：今月のリリースノート"] {
            XCTAssertTrue(
                app.staticTexts[subject].waitForExistence(timeout: 30),
                "Expected seeded message \"\(subject)\" to appear in the list"
            )
        }

        // The 3-message test1<->test2 References chain (09/10/11):
        // collapses to one row showing the latest message's subject
        // ("Re: 来週のランチ", from seed-0011) plus a "3" count badge.
        let list = app.collectionViews["messageList.list"]
        let threadRow = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "来週のランチ")).firstMatch
        XCTAssertTrue(threadRow.waitForExistence(timeout: 30), "Expected the References-linked thread to appear as one row")
        assertCountBadge(equals: "3", in: threadRow)

        // The References-free subject-fallback pair (12/13, "来月の懇親会に
        // ついて" / "Re: 来月の懇親会について") should also have collapsed to one
        // row with a "2" badge — confirms Threader's subject-fallback path
        // (no In-Reply-To/References at all) works end to end, not just the
        // References union-find path.
        let fallbackRow = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "懇親会について")).firstMatch
        XCTAssertTrue(fallbackRow.waitForExistence(timeout: 10), "Expected the subject-fallback thread to appear as one row")
        assertCountBadge(equals: "2", in: fallbackRow)
    }

    /// Looks for the row's `messageList.row.<id>.countBadge` static text
    /// (identifier-suffix `CONTAINS` lookup, not exact-match — see the
    /// verify skill's note on this simulator/toolchain sometimes failing
    /// exact identifier lookups for a plainly-visible element) and asserts
    /// its label is exactly `expected` — a plain `label CONTAINS expected`
    /// against the whole row would also spuriously match a digit that just
    /// happens to appear in the row's date text.
    private func assertCountBadge(equals expected: String, in row: XCUIElement) {
        let badge = row.staticTexts.matching(NSPredicate(format: "identifier CONTAINS %@", "countBadge")).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "Expected a count badge in the row")
        XCTAssertEqual(badge.label, expected, "Expected the count badge to read \"\(expected)\", got \"\(badge.label)\"")
    }
}
