import XCTest

/// Real-device contamination fix (`docs/icloud-sync.md`'s "開発用ビルドでの
/// iCloud KVS 汚染" section, `AppEnvironment.isCloudSyncPermittedOnThisBuild`'s
/// doc comment): a Simulator build of this app defaults to never talking to
/// `AccountCloudSyncEngine` at all, because — confirmed empirically on the
/// dev machine this fix shipped from — the Simulator's iCloud KVS traffic is
/// routed through the host Mac's real `cloudd`, using whatever real Apple ID
/// that Mac is signed into, hitting the exact same
/// `com.apple.developer.ubiquity-kvstore-identifier` container a real
/// Ad-Hoc-signed device build (`make deploy-ota`) does.
///
/// This suite doesn't (can't, from inside the app process) inspect the host
/// Mac's `cloudd` logs itself — that verification is
/// `scripts/verify-ios-cloud-sync-isolation.sh`, which wraps this test and
/// diffs `log show`'s `cloudd`/`com.apple.cloudkit:CK` "TCC approved access
/// for container ... com.mtkg.otegami" entries against a time window
/// bracketing this test's run. What this test does is the deterministic,
/// in-app half: add a dev-mailstack account (the exact scenario that seeded
/// the real device) on an ordinary Simulator launch — no
/// `-otegamiEnableCloudSyncInSimulator` opt-in — and let the app run long
/// enough that a launch-time `reconcile()` and an add-triggered
/// `pushLocalChange` would both have had every opportunity to fire if the
/// Simulator gate were broken.
final class OtegamiCloudSyncSimulatorIsolationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAddingADevMailstackAccountOnSimulatorDoesNotOptIntoCloudSync() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        // Deliberately *not* setting `-otegamiEnableCloudSyncInSimulator` —
        // this is the ordinary, default-gated launch every verify script and
        // `make ios` run already uses, which is exactly what contaminated
        // the real device before this fix.
        app.launch()

        addDovecotTest1Account(in: app)
        restartAppToRecoverTouchDelivery(app)
        XCTAssertTrue(
            waitForSeededSubjectScrollingIfNeeded("ようこそ otegami へ", in: app),
            "Expected the seeded baseline message to appear — this test is about cloud-sync isolation, not about the ordinary add-account flow regressing"
        )

        // Give the launch-time `reconcile()` Task and the account-add's
        // `pushAccountToCloud` Task (both fire-and-forget `Task { ... }`
        // calls in `AppEnvironment`) generous time to actually run before
        // the wrapping script closes its log-capture window — a false
        // "no cloudd traffic" pass because this test ended too early would
        // be worse than a slow test.
        Thread.sleep(forTimeInterval: 5)
    }
}
