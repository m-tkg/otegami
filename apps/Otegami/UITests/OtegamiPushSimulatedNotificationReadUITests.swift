import XCTest

/// Best-effort read of the most recent "Otegami" notification's *rendered
/// text* straight out of Notification Center's accessibility tree, as a
/// second, stronger signal alongside the screenshot
/// `scripts/verify-ios-push-simulated.sh` also takes after each
/// `xcrun simctl push` — the task's "XCUITestからspringboardの通知要素を読む
/// 方法があればそれも" ask. A screenshot needs a human (or Claude) to *read*
/// pixels; this reads the actual accessibility label XCUITest sees, so it
/// can distinguish "生の日本語件名が書き換わって出た" from "汎用フォールバック
/// のまま" by string content, not by eyeballing a PNG.
///
/// Springboard/Notification-Center automation isn't exercised anywhere else
/// in this project's verify suite — every other milestone only ever reads
/// the app's *own* UI (`docs/verify.md`'s M2/M4/M7 sections catalog several
/// simulator/toolchain-specific quirks in *that* much more heavily-used
/// path already). Treat this as a secondary, less-trusted signal: if a
/// future OS/toolchain revision changes how Notification Center's swipe
/// gesture or accessibility tree work, the wrapping script's screenshot
/// remains the fallback source of truth, same as every `m*-NN-*.png` this
/// project's other verify scripts already rely on Claude to visually judge.
final class OtegamiPushSimulatedNotificationReadUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testReadLatestOtegamiNotificationFromNotificationCenter() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()

        // Open Notification Center: drag down from just below the status
        // bar/Dynamic Island — the OS-level "swipe down from the top"
        // gesture, not any app UI (springboard owns this, not Otegami).
        let window = springboard.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: end)

        let notificationText = springboard.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Otegami"))
            .firstMatch
        let found = notificationText.waitForExistence(timeout: 10)
        if found {
            // Printed (not just asserted) so the wrapping shell script's
            // captured xcodebuild log has the literal delivered text for
            // each of the three scenarios (enriched / IMAP-unreachable
            // fallback / unknown-accountId fallback) to grep for and
            // report — the whole point of reading this over a screenshot.
            print("PUSH-VERIFY-NOTIFICATION-LABEL: \(notificationText.label)")
        } else {
            print("PUSH-VERIFY-NOTIFICATION-LABEL: <not found within 10s>")
        }
        XCTAssertTrue(found, "No \"Otegami\" notification entry found in Notification Center after the simctl push")
    }
}
