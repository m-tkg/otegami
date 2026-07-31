import SwiftUI
import WebKit
import OtegamiCore

/// 実機フィードバック第3弾 (C): one `WKProcessPool` shared by every
/// `HTMLMessageView` this app ever creates. `WKWebViewConfiguration
/// .processPool` defaults to a **brand-new** `WKProcessPool` per
/// configuration unless one is explicitly assigned — before this existed,
/// every single message opened (HTML or not, since `makeWebViewConfiguration`
/// runs regardless) spun up its own throwaway WebKit content process from
/// scratch, which is the primary suspect for the real-device report
/// "起動し直すと読み込みが入る。表示まで時間がかかる" (`docs/verify.md`'s C note
/// has the actual measured timings). Sharing one pool lets WebKit reuse an
/// already-running content process for the second and later message opens
/// in the same launch; `HTMLWebViewPrewarmer` (below) additionally warms
/// that first process up *before* the user's first tap, so a fresh launch
/// benefits too, not just repeat opens within one session.
@MainActor
enum HTMLWebViewProcessPool {
    static let shared = WKProcessPool()
}

/// 実機フィードバック第3弾 (C): kicked off once, in the background, from
/// `AppEnvironment.init()` — creates one throwaway, never-displayed
/// `WKWebView` sharing `HTMLWebViewProcessPool.shared` and loads a trivial
/// blank document into it, then keeps it alive for the rest of the process
/// (a `static var`, never deallocated) purely to keep that pool's content
/// process warm. `HTMLWebViewProcessPool` alone only helps the *second*
/// message a session opens — there's no already-running process yet for
/// the very first one on a cold launch, exactly the case the real-device
/// report called out ("起動し直すと"). Deliberately dispatched from a
/// `Task` (see the call site), not run synchronously inside `init()` —
/// spinning up a `WKWebView` has its own non-trivial cost, and blocking
/// `AppEnvironment.init()` (which runs synchronously before `RootView`'s
/// first render) on it would trade "message screen feels slow" for "app
/// launch feels slow", not actually fix anything.
@MainActor
enum HTMLWebViewPrewarmer {
    private static var warmWebView: WKWebView?

    static func prewarm() {
        guard warmWebView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.processPool = HTMLWebViewProcessPool.shared
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        warmWebView = webView
    }
}

/// A `WKWebViewConfiguration` with page-authored JavaScript disabled
/// (plan: "JS 無効") and, when `cidHandler` is provided, the
/// `otegami-cid://` scheme registered for inline `cid:` image resolution
/// (M8). Set once at configuration time — rather than per navigation via
/// the delegate's `decidePolicyFor:preferences:` — since every load this
/// view ever does should be equally restricted; there's no case where a
/// message body should be allowed to run script.
@MainActor
private func makeWebViewConfiguration(cidHandler: CIDSchemeHandler?) -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    // 実機フィードバック第3弾 (C) — see `HTMLWebViewProcessPool`'s doc comment.
    configuration.processPool = HTMLWebViewProcessPool.shared
    // Explicit even though it's already the default — makes clear this
    // view deliberately relies on WebKit's own persistent on-disk cache
    // (images, HTTP cache) surviving across app relaunches, rather than an
    // ephemeral (`.nonPersistent()`) store that would silently defeat the
    // "2回目以降はローカルから" requirement.
    configuration.websiteDataStore = .default()
    let preferences = WKWebpagePreferences()
    preferences.allowsContentJavaScript = false
    configuration.defaultWebpagePreferences = preferences
    if let cidHandler {
        configuration.setURLSchemeHandler(cidHandler, forURLScheme: CIDURLRewriter.scheme)
    }
    return configuration
}

#if os(iOS)
import UIKit

struct HTMLWebViewRepresentable: UIViewRepresentable {
    let html: String
    let allowsExternalContent: Bool
    let allowsEmbeddedImages: Bool
    /// Task #207 — see `HTMLMessageView.allowsPlaintextHTTPImages`'s doc
    /// comment.
    let allowsPlaintextHTTPImages: Bool
    let autoAdjustColorsInDarkMode: Bool
    /// Task #71 — see `HTMLMessageView.forceLightBackground`'s doc comment.
    let forceLightBackground: Bool
    /// Task #56 — see `HTMLMessageView.bottomContentInset`'s doc comment.
    let bottomContentInset: CGFloat
    let cidContext: CIDResolutionContext
    /// 1i — see `HTMLMessageView.translationController`'s doc comment.
    let translationController: HTMLTranslationController
    let onOpenLink: (URL) -> Void
    /// Task #58 — see `HTMLWebViewCoordinator.onHeightChange`'s doc comment.
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> HTMLWebViewCoordinator { HTMLWebViewCoordinator(cidContext: cidContext, onOpenLink: onOpenLink, onHeightChange: onHeightChange) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeWebViewConfiguration(cidHandler: context.coordinator.cidHandler))
        // Task #58 (根治): this document's own real content height is now
        // reported back (`otegamiHeight` message handler, registered below)
        // and used to size this web view's *actual* frame, up at
        // `ThreadMessageRow` — so this web view no longer needs (or should
        // rely on) its own internal scroll surface. Two independent
        // scrollers used to be nested (this `WKWebView`'s own `UIScrollView`
        // inside `ThreadDetailView`'s outer `ScrollView`), and on this
        // toolchain the outer one always won the pan gesture, making
        // whatever didn't fit in this web view's fixed frame silently
        // unreachable — not just badly measured, genuinely unscrollable.
        // Disabling this one leaves exactly one scroller, which is what
        // actually fixes that (see `docs/design-system.md`'s Task #58 note
        // for the full root-cause writeup).
        webView.scrollView.isScrollEnabled = false
        webView.configuration.userContentController.add(context.coordinator, name: HTMLWebViewCoordinator.heightMessageHandlerName)
        translationController.attach(to: webView)
        webView.navigationDelegate = context.coordinator
        // C7 バグ修正 (リンクがブラウザで開かない) — `HTMLWebViewCoordinator`
        // のdoc comment参照。real-device 固有と報告された不具合の有力な原因
        // の1つが `allowsLinkPreview`(既定 true): 実機の 3D/Haptic Touch が
        // リンクの長押しピーク・プレビューを認識しようとするジェスチャー
        // 認識器と、単純なタップの認識が競合し、タップが `decidePolicyFor`
        // まで届かないことがある — Simulator にはこのハードウェアがないため
        // design-phase-3 時点のシミュレータ検証では再現しなかった、という
        // 説明と整合する。ピーク・プレビュー自体もこのアプリでは使っていな
        // い機能なので、明示的に無効化する。
        webView.allowsLinkPreview = false
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // Task #80 (チラつき根絶): hidden until `HTMLWebViewCoordinator
        // .applyFitToWidth(to:)`'s reveal callback fires — see that
        // method's doc comment for why this is the right moment (same
        // luminance-measurement pass this app already runs, not a new
        // mechanism) and why hiding only here (this view's *first* load,
        // not every `reloadIfNeeded` reload) is deliberate.
        webView.alpha = 0
        context.coordinator.load(
            html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages,
            allowsPlaintextHTTPImages: allowsPlaintextHTTPImages,
            autoAdjustColorsInDarkMode: autoAdjustColorsInDarkMode, forceLightBackground: forceLightBackground,
            bottomContentInset: bottomContentInset, into: webView
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.reloadIfNeeded(
            html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages,
            allowsPlaintextHTTPImages: allowsPlaintextHTTPImages,
            autoAdjustColorsInDarkMode: autoAdjustColorsInDarkMode, forceLightBackground: forceLightBackground,
            bottomContentInset: bottomContentInset,
            cidContext: cidContext, into: webView
        )
    }
}
#elseif os(macOS)
import AppKit

struct HTMLWebViewRepresentable: NSViewRepresentable {
    let html: String
    let allowsExternalContent: Bool
    let allowsEmbeddedImages: Bool
    /// Task #207 — see `HTMLMessageView.allowsPlaintextHTTPImages`'s doc
    /// comment.
    let allowsPlaintextHTTPImages: Bool
    let autoAdjustColorsInDarkMode: Bool
    /// Task #71 — see `HTMLMessageView.forceLightBackground`'s doc comment.
    let forceLightBackground: Bool
    /// Task #56 — see `HTMLMessageView.bottomContentInset`'s doc comment.
    let bottomContentInset: CGFloat
    let cidContext: CIDResolutionContext
    /// 1i — see `HTMLMessageView.translationController`'s doc comment.
    let translationController: HTMLTranslationController
    let onOpenLink: (URL) -> Void
    /// Task #58 — see `HTMLWebViewCoordinator.onHeightChange`'s doc comment.
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> HTMLWebViewCoordinator { HTMLWebViewCoordinator(cidContext: cidContext, onOpenLink: onOpenLink, onHeightChange: onHeightChange) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeWebViewConfiguration(cidHandler: context.coordinator.cidHandler))
        // Task #58 — see the iOS `makeUIView`'s identical comment (this
        // repo's macOS layout doesn't nest `HTMLMessageView` inside its own
        // accordion `ScrollView` the way `ThreadDetailView`'s iOS-shared
        // implementation does today, but registering the same height
        // channel here keeps both platforms on one code path and leaves
        // room for macOS to opt into the same real-height sizing later
        // without another round of WKWebView plumbing).
        webView.configuration.userContentController.add(context.coordinator, name: HTMLWebViewCoordinator.heightMessageHandlerName)
        translationController.attach(to: webView)
        webView.navigationDelegate = context.coordinator
        // C7 バグ修正 — `allowsLinkPreview`はiOS専用のプロパティなので
        // macOSにはない。`target="_blank"`リンクの取りこぼし対策の
        // `uiDelegate`はプラットフォーム共通で必要なので、iOS側と同じく
        // ここでも設定する。
        webView.uiDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        // Task #80 — see the iOS `makeUIView`'s identical comment.
        webView.alphaValue = 0
        context.coordinator.load(
            html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages,
            allowsPlaintextHTTPImages: allowsPlaintextHTTPImages,
            autoAdjustColorsInDarkMode: autoAdjustColorsInDarkMode, forceLightBackground: forceLightBackground,
            bottomContentInset: bottomContentInset, into: webView
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.reloadIfNeeded(
            html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages,
            allowsPlaintextHTTPImages: allowsPlaintextHTTPImages,
            autoAdjustColorsInDarkMode: autoAdjustColorsInDarkMode, forceLightBackground: forceLightBackground,
            bottomContentInset: bottomContentInset,
            cidContext: cidContext, into: webView
        )
    }
}
#endif
