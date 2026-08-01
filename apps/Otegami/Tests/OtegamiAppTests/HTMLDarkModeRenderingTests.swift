import Testing
import WebKit
@testable import Otegami

@MainActor
@Suite("HTML dark-mode rendering")
struct HTMLDarkModeRenderingTests {
    @Test("legacy mixed light palette stays on a light canvas")
    func legacyMixedLightPaletteKeepsLightCanvas() async throws {
        let messageHTML = """
        <html><body>
          <table>
            <tr style="color:#333"><td>
              <p>基準価額のお知らせ</p>
              <p>対象ファンド一覧</p>
            </td></tr>
          </table>
          <table>
            <tr style="background-color:#e1edf3">
              <th>ファンド名</th><th>基準価額</th><th>前週比</th><th>リターン</th>
            </tr>
            <tr><td>サンプルファンド</td><td>12,345円</td><td>-123円</td><td>20.5%</td></tr>
          </table>
        </body></html>
        """
        let document = HTMLDocumentBuilder.wrap(
            bodyHTML: messageHTML,
            autoAdjustColorsInDarkMode: false
        )
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844))
        let viewController = UIViewController()
        viewController.overrideUserInterfaceStyle = .dark
        let window = UIWindow(frame: webView.frame)
        window.rootViewController = viewController
        viewController.view.addSubview(webView)
        window.isHidden = false
        let navigation = NavigationWaiter()
        webView.navigationDelegate = navigation

        await navigation.load(document, in: webView)
        HTMLWebViewCoordinator.applyFitToWidth(to: webView)
        try await Task.sleep(for: .milliseconds(100))

        let htmlClass = try #require(
            await webView.evaluateJavaScript("document.documentElement.className") as? String
        )
        let headingColor = try #require(
            await webView.evaluateJavaScript("getComputedStyle(document.querySelector('th')).color") as? String
        )
        let bodyBackground = try #require(
            await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
        )
        #expect(htmlClass.contains("otegami-keep-light-active"))
        #expect(headingColor == "rgb(0, 0, 0)")
        #expect(bodyBackground == "rgb(255, 255, 255)")
        window.isHidden = true
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?

    func load(_ html: String, in webView: WKWebView) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }
}
