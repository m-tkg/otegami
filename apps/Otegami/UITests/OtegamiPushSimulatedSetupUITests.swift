import XCTest

/// Setup phase for `scripts/verify-ios-push-simulated.sh` (M9's
/// "`xcrun simctl push` によるシミュレータへのペイロード注入テスト" follow-up):
/// adds the dev mailstack's `test1@otegami.test` Dovecot account so its
/// `AccountRecord.id`/Keychain password exist for the wrapping shell script
/// to read (via `sqlite3` against the App Group container's
/// `otegami.sqlite` — `OtegamiStore.AppDatabase`'s doc comment) and hand to
/// `xcrun simctl push`'s injected payload (`accountId`) — the exact same
/// "host drives an external event, then inspects app-persisted state"
/// pattern `docs/verify.md`'s M3 section documents for why XCUITest itself
/// can't shell out to read the mailstack (`Foundation.Process` is
/// unavailable on iOS) or drive `simctl push` (that's a host-only command,
/// nothing to do with the app process at all).
///
/// Deliberately mirrors `addDovecotTest1Account` (M1) rather than
/// `addDovecotTest1AccountWithSMTP` (M5) — `NotificationService` only ever
/// does an IMAP round trip, no SMTP needed for this verification.
final class OtegamiPushSimulatedSetupUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddTest1AccountForPushVerification() throws {
        let app = XCUIApplication()
        app.launch()

        let emptyStateButton = app.buttons["mail.addAccountButton"]
        if emptyStateButton.waitForExistence(timeout: 5) {
            try addDovecotTest1Account(in: app)
            restartAppToRecoverTouchDelivery(app)
        }
        // else: an account already exists from a previous run of this
        // script against the same (not-yet-erased) simulator install —
        // idempotent by design, matching M9's own setup phase reasoning.

        navigateToUnifiedInboxIfNeeded(in: app)
        XCTAssertTrue(
            waitForSeededSubjectScrollingIfNeeded("ようこそ otegami へ", in: app),
            "test1's seeded baseline message never appeared — the account isn't usable, injecting a push against it would be meaningless"
        )

        // M9 bug fix follow-up: `xcrun simctl push` refuses to deliver any
        // `aps.alert` payload to an app that has never been granted
        // `UNUserNotificationCenter` authorization (`UNErrorDomain
        // code=2003 "Source is not authorized"` — see this suite's
        // companion `scripts/verify-ios-push-simulated.sh` and
        // `docs/verify.md`'s "M9 追補" section for the full writeup of this
        // blocker and its fix). Drive the push-settings "有効にする" flow
        // once here, purely to trigger and accept that OS-level permission
        // prompt, before the wrapping script's first `simctl push`.
        grantNotificationPermissionViaPushSettings(in: app)

        // Leave the app terminated: `NotificationService` is a *separate*
        // process from the containing app (the entire point of M9's
        // extension design — it must enrich a push whether or not the app
        // itself is running), so the wrapping shell script's
        // `xcrun simctl push` step should exercise that independence
        // rather than accidentally relying on the app being foregrounded.
        app.terminate()
    }
}
