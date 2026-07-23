import SwiftUI
import WebKit
import OtegamiCore

/// Renders an HTML message body: a `WKWebView` with page JavaScript
/// disabled and external (`http`/`https`) resources blocked by default via
/// a `WKContentRuleList`, plus a "画像を表示" banner (shown whenever the
/// HTML references an external resource) that lifts the block and reloads
/// — for that message, for the rest of this app session only; a relaunch
/// (or opening a different message) goes back to blocking by default.
///
/// The web view scrolls internally (rather than the SwiftUI-side content
/// being measured and sized to fit an outer `ScrollView`) — simpler and
/// more robust than measuring rendered height via injected JavaScript,
/// which would have needed page JavaScript to be at least partially
/// enabled just to answer "how tall is this content". `MessageView` gives
/// this view the remaining space below its (non-scrolling) header instead
/// of nesting it inside its own `ScrollView`.
struct HTMLMessageView: View {
    let html: String

    @State private var allowsExternalContent = false

    private var hasExternalContent: Bool {
        HTMLExternalResourceScanner.containsExternalResource(html: html)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasExternalContent && !allowsExternalContent {
                Button {
                    allowsExternalContent = true
                } label: {
                    Label("画像を表示", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
                .padding(.top, 4)
                .accessibilityIdentifier("messageDetail.showImagesBanner")
            }

            HTMLWebViewRepresentable(html: html, allowsExternalContent: allowsExternalContent)
                .accessibilityIdentifier("messageDetail.htmlWebView")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The full HTML document loaded into the web view: wraps the message's
/// body-only HTML (`MessageBodyContent.html`, from MailCore2's
/// `htmlBodyRendering()`) with a minimal reset so it reads legibly in both
/// light and dark mode without the message's own styling fighting the
/// app's chrome (plan: "背景透過・文字色継承・max-width: 100%・画像縮小").
enum HTMLDocumentBuilder {
    static func wrap(bodyHTML: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; }
          html, body {
            margin: 0;
            padding: 0;
            background: transparent;
            color: CanvasText;
            font: -apple-system-body;
            -webkit-text-size-adjust: 100%;
            word-wrap: break-word;
            overflow-wrap: break-word;
          }
          body { padding: 8px 12px; }
          * { max-width: 100% !important; box-sizing: border-box; }
          img, video, table, iframe { max-width: 100% !important; height: auto !important; }
          a { color: LinkText; }
          pre, code { white-space: pre-wrap; }
        </style>
        </head>
        <body>\(bodyHTML)</body>
        </html>
        """
    }
}

/// A `WKWebViewConfiguration` with page-authored JavaScript disabled
/// (plan: "JS 無効"). Set once at configuration time — rather than per
/// navigation via the delegate's `decidePolicyFor:preferences:` — since
/// every load this view ever does should be equally restricted; there's
/// no case where a message body should be allowed to run script.
private func makeWebViewConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    let preferences = WKWebpagePreferences()
    preferences.allowsContentJavaScript = false
    configuration.defaultWebpagePreferences = preferences
    return configuration
}

#if os(iOS)
import UIKit

struct HTMLWebViewRepresentable: UIViewRepresentable {
    let html: String
    let allowsExternalContent: Bool

    func makeCoordinator() -> HTMLWebViewCoordinator { HTMLWebViewCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.load(html: html, allowsExternalContent: allowsExternalContent, into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.reloadIfNeeded(html: html, allowsExternalContent: allowsExternalContent, into: webView)
    }
}
#elseif os(macOS)
import AppKit

struct HTMLWebViewRepresentable: NSViewRepresentable {
    let html: String
    let allowsExternalContent: Bool

    func makeCoordinator() -> HTMLWebViewCoordinator { HTMLWebViewCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        context.coordinator.load(html: html, allowsExternalContent: allowsExternalContent, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.reloadIfNeeded(html: html, allowsExternalContent: allowsExternalContent, into: webView)
    }
}
#endif

/// Compiles (once, cached by `WKContentRuleListStore` under its fixed
/// identifier) and applies/removes the content-blocking rule list, then
/// loads the wrapped HTML.
@MainActor
final class HTMLWebViewCoordinator: NSObject, WKNavigationDelegate {
    /// Blocks every `http(s)://` subresource request. Loading the message
    /// itself via `loadHTMLString(_:baseURL:)` is not itself a network
    /// request, so this only ever blocks things the HTML *references*
    /// (images, iframes, ...), never the message content itself.
    private static let blockAllRemoteResourcesRuleList = """
    [{"trigger": {"url-filter": "^https?://.*"}, "action": {"type": "block"}}]
    """

    private static let ruleListIdentifier = "otegami.blockAllRemoteResources"

    private var lastLoadedHTML: String?
    private var lastAllowsExternalContent: Bool?

    func reloadIfNeeded(html: String, allowsExternalContent: Bool, into webView: WKWebView) {
        guard html != lastLoadedHTML || allowsExternalContent != lastAllowsExternalContent else { return }
        load(html: html, allowsExternalContent: allowsExternalContent, into: webView)
    }

    func load(html: String, allowsExternalContent: Bool, into webView: WKWebView) {
        lastLoadedHTML = html
        lastAllowsExternalContent = allowsExternalContent

        let document = HTMLDocumentBuilder.wrap(bodyHTML: html)

        applyContentRuleList(blocked: !allowsExternalContent, to: webView) { [weak webView] in
            guard let webView else { return }
            webView.loadHTMLString(document, baseURL: nil)
        }
    }

    private func applyContentRuleList(blocked: Bool, to webView: WKWebView, completion: @escaping () -> Void) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        guard blocked else {
            completion()
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: Self.ruleListIdentifier,
            encodedContentRuleList: Self.blockAllRemoteResourcesRuleList
        ) { ruleList, _ in
            // A compile failure (shouldn't happen for this fixed, valid
            // rule list) just means external content loads unblocked
            // rather than the message failing to render at all.
            if let ruleList {
                controller.add(ruleList)
            }
            completion()
        }
    }

    /// Any navigation other than the initial `loadHTMLString` (a user
    /// somehow tapping a link, a resource redirect, ...) is refused rather
    /// than followed inline — mail HTML is not a place this app should be
    /// browsing the web from.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .other {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }
}
