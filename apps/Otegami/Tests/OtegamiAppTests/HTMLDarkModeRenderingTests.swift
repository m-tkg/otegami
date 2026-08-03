import Testing
import WebKit
@testable import Otegami

@MainActor
@Suite("HTML message rendering")
struct HTMLDarkModeRenderingTests {
    @Test("bare HTTP URLs become links without nesting existing links")
    func bareHTTPURLsBecomeLinks() async throws {
        let messageHTML = """
        <html><body>
          <p>詳細: https://example.com/report/2026。</p>
          <p><a href="https://example.com/existing">既存リンク</a></p>
          <code>https://example.com/code-sample</code>
        </body></html>
        """
        let document = HTMLDocumentBuilder.wrap(
            bodyHTML: messageHTML,
            autoAdjustColorsInDarkMode: false
        )
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844))
        let navigation = NavigationWaiter()
        webView.navigationDelegate = navigation

        await navigation.load(document, in: webView)
        HTMLWebViewCoordinator.applyFitToWidth(to: webView)
        try await Task.sleep(for: .milliseconds(100))

        let linkCount = try #require(
            await webView.evaluateJavaScript("document.querySelectorAll('a').length") as? Int
        )
        let autoLinkHref = try #require(
            await webView.evaluateJavaScript("document.querySelector('[data-otegami-auto-link]').href") as? String
        )
        let codeContainsLink = try #require(
            await webView.evaluateJavaScript("document.querySelector('code a') !== null") as? Bool
        )
        let autoLinkDecoration = try #require(
            await webView.evaluateJavaScript("getComputedStyle(document.querySelector('[data-otegami-auto-link]')).textDecorationLine") as? String
        )
        #expect(linkCount == 2)
        #expect(autoLinkHref == "https://example.com/report/2026")
        #expect(!codeContainsLink)
        #expect(autoLinkDecoration == "underline")
    }

    /// 実機報告 (楽天証券のアンケート依頼メール、内容は伏せて構造だけ再現):
    /// `<body bgcolor="#ffffff">` で白背景を宣言し、`<style>` の
    /// `body, div, ... { color: #333 }` で暗色文字を指定するメールが、
    /// ダークモードで「アプリの暗背景 + #333 文字」に沈んだ。原因は
    /// `HTMLDocumentBuilder.extractBodyContent` が `<body ...>` 開きタグの
    /// 属性ごと捨てるため、著者の白背景宣言 (`bgcolor`) だけが消失し、
    /// `<style>` 経由の暗色文字だけが生き残ること。背景の消失は JS 側の
    /// 背景解決 (`findEffectiveBackground` の `document.body` tier) の判定
    /// 材料まで奪うので、keep-light 救済も発動しない二重の障害になる。
    @Test("body bgcolor attribute survives wrapping as the canvas color")
    func bodyBgcolorAttributeKeepsLightCanvas() async throws {
        let messageHTML = """
        <html><head>
        <style type="text/css" media="screen">
        body, div, h1, h2, h3, h4, h5, h6, strong { margin: 0; padding: 0; color: #333; font-size: 16px; }
        </style>
        </head>
        <body bgcolor="#ffffff" style="font-family: sans-serif;">
        <table width="99%" border="0"><tr><td align="center">
          <table width="550" border="0">
            <tr><td align="left" style="font-size: 18px; line-height: 1.7;">平素よりご愛顧いただき、誠にありがとうございます。<br>
              よりよいサービスをご提供するためにアンケートを実施しております。<br>
              回答にご協力いただいたお客様には、<span style="color: #ED4C6B; font-weight:bold;">ポイントを進呈</span>いたします。</td></tr>
            <tr><td><table bgcolor="#ED4C6B" width="550" cellpadding="1"><tr><td>
              <table bgcolor="#FFFFFF" width="546" cellpadding="2"><tr>
                <td align="left" style="font-size: 18px; font-weight:bold; color: #ED4C6B;">■アンケートについて</td>
              </tr></table>
            </td></tr></table></td></tr>
          </table>
        </td></tr></table>
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

        let innerBackground = try #require(
            await webView.evaluateJavaScript("getComputedStyle(document.getElementById('otegami-fit-inner')).backgroundColor") as? String
        )
        let htmlClass = try #require(
            await webView.evaluateJavaScript("document.documentElement.className") as? String
        )
        #expect(innerBackground == "rgb(255, 255, 255)")
        #expect(htmlClass.contains("otegami-keep-light-active"))
        window.isHidden = true
    }

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
