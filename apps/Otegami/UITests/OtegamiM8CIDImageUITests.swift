import XCTest
import UIKit

/// M8 verification, phase 2 (b): open the cid-inline-image HTML seed
/// message (`16-cid-inline-image.eml`), confirm the surrounding HTML text
/// renders (proving the message loaded and the `WKWebView` navigated
/// successfully), confirm the "画像を表示" external-image banner does *not*
/// appear — this message has no `http(s)://` references at all, only a
/// `cid:` one, so the banner's absence demonstrates the inline image path
/// is independent of (and unaffected by) the external-resource block, per
/// the plan's "外部画像ブロックとは独立に動くこと" — and, since the fix for
/// the M8/QA-sweep-era cid resolution bug (`docs/qa-findings.md`:
/// `CIDURLRewriter`/`CIDSchemeHandler` mishandling a `Content-ID` containing
/// `@`), actually verify the image *pixels* rendered rather than trusting
/// the accessibility-tree-only checks that previously let a completely
/// broken inline image pass unnoticed for several milestones. `<img>`
/// elements inside a `WKWebView` aren't individually exposed to XCUITest's
/// accessibility tree, so ``countPixels(in:approximatelyMatching:tolerance:)``
/// scans a real screenshot for the seed fixture's distinctive solid-color
/// pixels instead — see its doc comment.
final class OtegamiM8CIDImageUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCIDInlineImageMessageRendersWithoutExternalImageBanner() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        app.launch()

        // No `popBackOnceIfNeeded` here — `RootView`'s "last opened
        // thread" restoration is same-session-only now (docs/verify.md),
        // so a fresh launch with an existing account always starts
        // *already on* the message list. Popping here would overshoot
        // past the list to the sidebar instead.
        let list = app.collectionViews["messageList.list"]
        let row = list.cells.containing(NSPredicate(format: "label CONTAINS %@", "インライン画像つきHTMLメール")).firstMatch
        XCTAssertTrue(
            waitForElementScrollingIfNeeded(row, in: app),
            "Expected the cid-inline-image seed message to appear"
        )
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)

        // `HTMLMessageView`'s WKWebView content surfaces as static text in
        // the accessibility tree (M2's established pattern) — search with
        // `CONTAINS` across all static texts rather than a scoped/exact
        // lookup, per verify.md's M2 note on WebKit's accessibility
        // grouping being unpredictable.
        let bodyText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "cid 解決は成功です")).firstMatch
        XCTAssertTrue(bodyText.waitForExistence(timeout: 20), "Expected the cid-image message's HTML body text to render")

        XCTAssertFalse(
            app.buttons["messageDetail.showImagesBanner"].exists,
            "The external-image banner should not appear for a message with only a cid: reference, no http(s):// ones"
        )

        // The `<img>` sits below the visible fold on launch (`docs/roadmap.md`'s
        // former "cid 画像は画面外なのでスクロールしてから撮る" open item) —
        // scroll the web view down before either the pixel check below or
        // the wrapping shell script's mid-test screenshot, so both actually
        // see the image instead of just the header/first paragraph.
        let webView = app.webViews["messageDetail.htmlWebView"]
        if webView.waitForExistence(timeout: 5) {
            webView.swipeUp()
        }
        Thread.sleep(forTimeInterval: 1) // let the scroll animation settle

        // Real pixel-level verification that the image actually rendered —
        // not just "no broken-image icon", which nothing here can assert on
        // via the accessibility tree anyway (see this file's doc comment).
        // The seed fixture's inline PNG (`dev/mailstack/seed/fixtures
        // /16-cid-inline-image.eml`) is a solid RGB(232,122,30) 24×24
        // square, a color that appears nowhere else on this screen (white
        // background, black/gray body text, the system nav bar tint) —
        // finding a sizable cluster of matching pixels in a fresh
        // screenshot is a strong, automatable signal the `<img>` loaded its
        // actual bytes. This is exactly the check that would have caught
        // the M8-era `CIDURLRewriter`/`CIDSchemeHandler` `@`-in-Content-ID
        // bug (`docs/qa-findings.md`) immediately, instead of it going
        // unnoticed until a much later manual screenshot review.
        let screenshot = XCUIScreen.main.screenshot().image
        let matchingPixels = Self.countPixels(in: screenshot, approximatelyMatching: (r: 232, g: 122, b: 30), tolerance: 20)
        XCTAssertGreaterThan(
            matchingPixels, 50,
            "Expected a cluster of the seed logo's solid orange (232,122,30) pixels somewhere on screen — the cid: inline image doesn't appear to have rendered (found \(matchingPixels) matching pixels)"
        )

        // Hold the message open for the wrapping shell script's mid-test
        // screenshot (same technique as `OtegamiM8AttachmentUITests`).
        Thread.sleep(forTimeInterval: 4)
    }

    /// Counts pixels in `image` within `tolerance` of `target` per RGB
    /// channel — a blunt but effective way to assert "this exact
    /// solid-color test image rendered somewhere on screen" without
    /// needing `WKWebView` to expose `<img>` elements individually to the
    /// accessibility tree (it doesn't).
    private static func countPixels(
        in image: UIImage,
        approximatelyMatching target: (r: UInt8, g: UInt8, b: UInt8),
        tolerance: Int
    ) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return 0 }

        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var count = 0
        var index = 0
        while index < pixelData.count {
            let r = Int(pixelData[index])
            let g = Int(pixelData[index + 1])
            let b = Int(pixelData[index + 2])
            if abs(r - Int(target.r)) <= tolerance, abs(g - Int(target.g)) <= tolerance, abs(b - Int(target.b)) <= tolerance {
                count += 1
            }
            index += 4
        }
        return count
    }
}
