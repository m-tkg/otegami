import Foundation
import WebKit
import OtegamiCore
import os

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

    /// Task #207: blocks only plaintext `http://` subresource requests,
    /// leaving `https://` untouched — confirmed feasible: `WKContentRuleList`
    /// matches `url-filter` against the full request URL as a plain regex,
    /// so anchoring on the literal scheme (`^http://`, no `s`) is sufficient
    /// to exclude `https://` without a negative lookahead (an `https://` URL
    /// can never match `^http://`, since the character right after `http` is
    /// `s`, not `:`). Used instead of `blockAllRemoteResourcesRuleList`
    /// whenever `allowsExternalContent` is already true (remote images in
    /// general are allowed) but `allowsPlaintextHTTPImages` isn't yet — see
    /// `RemoteContentBlockMode`/`load(...)` below for how the two rule lists
    /// are chosen between.
    private static let blockPlaintextHTTPResourcesRuleList = """
    [{"trigger": {"url-filter": "^http://.*"}, "action": {"type": "block"}}]
    """

    private static let httpOnlyRuleListIdentifier = "otegami.blockPlaintextHTTPResources"

    /// Task #207: which (if either) of the two rule lists above should be
    /// active for the current combination of `allowsExternalContent`/
    /// `allowsPlaintextHTTPImages`. `https` images stay governed by
    /// `allowsExternalContent` alone, unchanged from before this task —
    /// `.httpOnly` only ever narrows what's blocked relative to `.allRemote`,
    /// it never blocks anything `.allRemote` wouldn't already have blocked.
    private enum RemoteContentBlockMode: Equatable {
        case none
        case httpOnly
        case allRemote
    }

    /// M8: the `WKURLSchemeHandler` for `otegami-cid://`, created once
    /// (`WKWebViewConfiguration.setURLSchemeHandler` can only be called
    /// before the web view's first load — it isn't something `load(html:
    /// allowsExternalContent:into:)` could re-register per navigation the
    /// way the content rule list is re-applied). `mailboxPath` in
    /// particular can still be `nil` on the coordinator's very first
    /// `init` in principle (see `HTMLMessageView`'s doc comment for why
    /// that shouldn't actually happen given how `MessageView.load()`
    /// sequences its state), so `updateContext` keeps it current on every
    /// `reloadIfNeeded` regardless.
    let cidHandler: CIDSchemeHandler?

    /// C7: forwarded from `HTMLMessageView.handleLinkTap` — called from
    /// `decidePolicyFor` for any `http(s)://` link tap, after that
    /// navigation has already been cancelled in-place.
    private let onOpenLink: (URL) -> Void

    /// Task #58 (根治): the document's real, full content height (in CSS
    /// px, which this app's viewport makes equal to points) — see
    /// `heightReportingScript`'s doc comment for how it's measured and
    /// posted. `HTMLWebViewRepresentable` forwards whatever `HTMLMessageView`
    /// was given, which threads all the way up to `ThreadMessageRow`
    /// (`ThreadDetailView.swift`) — that's the view that actually owns the
    /// fixed-height budget this document used to be silently clipped to
    /// (`docs/design-system.md`'s Task #58 note has the full root-cause
    /// writeup), so this callback is what lets that budget grow to match
    /// real content instead of guessing a constant.
    private let onHeightChange: (CGFloat) -> Void

    init(cidContext: CIDResolutionContext, onOpenLink: @escaping (URL) -> Void, onHeightChange: @escaping (CGFloat) -> Void) {
        self.cidHandler = CIDSchemeHandler(context: cidContext)
        self.onOpenLink = onOpenLink
        self.onHeightChange = onHeightChange
    }

    private var lastLoadedHTML: String?
    private var lastAllowsExternalContent: Bool?
    private var lastAllowsEmbeddedImages: Bool?
    /// Task #207 — mirrors the two `lastAllows...` flags above, same
    /// reasoning: tracked so `reloadIfNeeded` reloads (and re-applies the
    /// content rule list) when only this flips, e.g. the user confirms the
    /// "保護されていない画像を確認" alert mid-view.
    private var lastAllowsPlaintextHTTPImages: Bool?
    /// Task #45 — mirrors the two `lastAllows...` flags above: needs to be
    /// tracked separately so `reloadIfNeeded` reloads the document when only
    /// this setting flips (e.g. the user toggles it in Settings while a
    /// message is still open), the same way it already does for the image
    /// settings.
    private var lastAutoAdjustColorsInDarkMode: Bool?
    /// Task #71 — mirrors `lastAutoAdjustColorsInDarkMode` immediately above,
    /// same reasoning.
    private var lastForceLightBackground: Bool?
    /// Task #56 — mirrors the flags above: tracked so `reloadIfNeeded`
    /// reloads (re-injects the bottom spacer, `HTMLDocumentBuilder.wrap`'s
    /// doc comment) when only this changes, e.g. the AI要約/翻訳 floating
    /// buttons appear/disappear for the same open message (a translation
    /// becoming available mid-view is the realistic case).
    private var lastBottomContentInset: CGFloat?

    /// C7 real-device/real-simulator bug fix. Extensive diagnostic
    /// instrumentation (temporary `UserDefaults`-marker tracing —
    /// `docs/verify.md`'s C7 section — from before this fix) proved, on
    /// this project's current toolchain, all of the following at once:
    ///  1. A tap on a plain `<a href="https://...">` link *does* reach the
    ///     `WKWebView`'s native UIKit view hierarchy (confirmed with a
    ///     bare `UITapGestureRecognizer` added directly to the web view —
    ///     it fires at the correct on-screen coordinate).
    ///  2. WebKit *does* act on that tap as a real navigation — a second
    ///     `didFinish` fires after the tap, for content this app never
    ///     asked to load.
    ///  3. Despite (1) and (2), **neither `decidePolicyFor` (this type's
    ///     `WKNavigationDelegate` conformance below) nor
    ///     `createWebViewWith` (`WKUIDelegate`, further below) is ever
    ///     invoked for that navigation** — confirmed by instrumenting both
    ///     with the same tracer and seeing neither log a single call, for
    ///     the entire lifetime of the view including the tap.
    /// In other words: on this toolchain, WKWebView silently navigates a
    /// tapped link in place *without* ever consulting either delegate this
    /// app relies on to intercept it — a genuine platform-level anomaly
    /// (standard `WKNavigationDelegate` usage, not a bug in this app's
    /// delegate implementation), not something fixable by changing what
    /// those delegate methods themselves do. `WKWebView.url` is a plain
    /// KVO-observable property that WebKit updates as part of any
    /// navigation, entirely independent of delegate dispatch — this
    /// observer is a delegate-independent fallback that watches for that
    /// URL becoming an `http(s)://` address (the tell-tale sign of exactly
    /// this stray in-place navigation, since this app never itself loads
    /// anything but `loadHTMLString(_:baseURL: nil)`, whose `url` is never
    /// `http(s)`) and, when it does, immediately stops that navigation and
    /// reloads this message's own content to undo it, then forwards the
    /// tapped URL to `onOpenLink` exactly as `decidePolicyFor` would have.
    /// Harmless on a toolchain where `decidePolicyFor` *does* fire
    /// normally: a properly cancelled navigation never updates `url` to
    /// the external address in the first place, so this observer simply
    /// never has anything to act on there.
    private var strayNavigationObservation: NSKeyValueObservation?

    private func observeStrayNavigations(on webView: WKWebView) {
        guard strayNavigationObservation == nil else { return }
        strayNavigationObservation = webView.observe(\.url, options: [.new]) { [weak self, weak webView] _, change in
            guard let self, let webView, let url = change.newValue ?? nil else { return }
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
            Task { @MainActor in
                self.recoverFromStrayNavigation(to: url, on: webView)
            }
        }
    }

    private func recoverFromStrayNavigation(to url: URL, on webView: WKWebView) {
        webView.stopLoading()
        if let html = lastLoadedHTML, let allowsExternalContent = lastAllowsExternalContent, let allowsEmbeddedImages = lastAllowsEmbeddedImages {
            load(
                html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages,
                // Task #207: fail safe (block) rather than fail open if this
                // is somehow ever nil — never re-show a plaintext-http image
                // this recovery path didn't itself just decide to.
                allowsPlaintextHTTPImages: lastAllowsPlaintextHTTPImages ?? false,
                autoAdjustColorsInDarkMode: lastAutoAdjustColorsInDarkMode ?? HTMLDisplaySettingsStore.defaultAutoAdjustColorsInDarkMode,
                forceLightBackground: lastForceLightBackground ?? HTMLDisplaySettingsStore.defaultForceLightBackground,
                bottomContentInset: lastBottomContentInset ?? 0,
                into: webView
            )
        }
        onOpenLink(url)
    }

    func reloadIfNeeded(
        html: String, allowsExternalContent: Bool, allowsEmbeddedImages: Bool, allowsPlaintextHTTPImages: Bool,
        autoAdjustColorsInDarkMode: Bool,
        forceLightBackground: Bool,
        bottomContentInset: CGFloat, cidContext: CIDResolutionContext, into webView: WKWebView
    ) {
        cidHandler?.updateContext(cidContext)
        guard html != lastLoadedHTML
            || allowsExternalContent != lastAllowsExternalContent
            || allowsEmbeddedImages != lastAllowsEmbeddedImages
            || allowsPlaintextHTTPImages != lastAllowsPlaintextHTTPImages
            || autoAdjustColorsInDarkMode != lastAutoAdjustColorsInDarkMode
            || forceLightBackground != lastForceLightBackground
            || bottomContentInset != lastBottomContentInset
        else { return }
        load(
            html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages,
            allowsPlaintextHTTPImages: allowsPlaintextHTTPImages,
            autoAdjustColorsInDarkMode: autoAdjustColorsInDarkMode, forceLightBackground: forceLightBackground,
            bottomContentInset: bottomContentInset, into: webView
        )
    }

    func load(
        html: String, allowsExternalContent: Bool, allowsEmbeddedImages: Bool, allowsPlaintextHTTPImages: Bool = false,
        autoAdjustColorsInDarkMode: Bool,
        forceLightBackground: Bool = false,
        bottomContentInset: CGFloat = 0, into webView: WKWebView
    ) {
        observeStrayNavigations(on: webView)
        lastLoadedHTML = html
        lastAllowsExternalContent = allowsExternalContent
        lastAllowsEmbeddedImages = allowsEmbeddedImages
        lastAllowsPlaintextHTTPImages = allowsPlaintextHTTPImages
        lastAutoAdjustColorsInDarkMode = autoAdjustColorsInDarkMode
        lastForceLightBackground = forceLightBackground
        lastBottomContentInset = bottomContentInset

        // B5: rewrite cid: references to the otegami-cid:// scheme *only*
        // when embedded images are currently allowed — independent of
        // `allowsExternalContent`/the content rule list below, which only
        // ever matches `^https?://` and so never touches this custom scheme
        // either way (plan: "外部画像ブロックとは独立に動くこと"). When
        // embedded images are off, `cid:` references are left as literal
        // `src="cid:..."` — WebKit has no handler for a bare `cid:` scheme,
        // so it simply fails to load that image (the same "broken image"
        // outcome a blocked remote image already produces), which is the
        // intended "don't auto-show" behavior.
        let cidRewrittenHTML = allowsEmbeddedImages ? CIDURLRewriter.rewrite(html: html) : html
        let document = HTMLDocumentBuilder.wrap(
            bodyHTML: cidRewrittenHTML, autoAdjustColorsInDarkMode: autoAdjustColorsInDarkMode,
            forceLightBackground: forceLightBackground, bottomContentInset: bottomContentInset
        )

        // Task #207: `https` stays governed by `allowsExternalContent`
        // alone (unchanged) — the http-only rule list only ever applies
        // once general remote images are already allowed, narrowing what's
        // still blocked down to plaintext `http` specifically.
        let blockMode: RemoteContentBlockMode = !allowsExternalContent
            ? .allRemote
            : (!allowsPlaintextHTTPImages ? .httpOnly : .none)
        applyContentRuleList(mode: blockMode, to: webView) { [weak webView] in
            guard let webView else { return }
            webView.loadHTMLString(document, baseURL: nil)
        }
    }

    private func applyContentRuleList(mode: RemoteContentBlockMode, to webView: WKWebView, completion: @escaping () -> Void) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        guard mode != .none else {
            completion()
            return
        }
        let identifier = mode == .allRemote ? Self.ruleListIdentifier : Self.httpOnlyRuleListIdentifier
        let encodedRuleList = mode == .allRemote ? Self.blockAllRemoteResourcesRuleList : Self.blockPlaintextHTTPResourcesRuleList
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: encodedRuleList
        ) { ruleList, _ in
            // A compile failure (shouldn't happen for these fixed, valid
            // rule lists) just means external content loads unblocked
            // rather than the message failing to render at all.
            if let ruleList {
                controller.add(ruleList)
            }
            completion()
        }
    }

    // MARK: - fit-to-width

    /// `HTMLDocumentBuilder.wrap(bodyHTML:)`'s "fit-to-width" doc comment
    /// explains *why*; this is the *how*. Idempotent (safe to run more than
    /// once against the same, unchanged DOM — resets any previous scale
    /// first), which is what makes it safe for 1i's HTML-preserving
    /// translation (`HTMLTranslationController`) to re-run it after
    /// rewriting text nodes, since a translated string is rarely the exact
    /// same pixel width as its original.
    ///
    /// Measures against `outer.clientWidth` (the actual available content
    /// width inside `body`'s own padding), not
    /// `document.documentElement.clientWidth` (the raw viewport width,
    /// which would overstate the budget by `body`'s left+right padding and
    /// leave a sliver still clipped at the edge).
    ///
    /// 本文が途中で切れる不具合の根本原因と修正 (実機フィードバック):
    /// `didFinish`(ページの`load`イベント) は仕様上「参照されている画像も
    /// 読み込み終わってから発火する」はずだが、`CIDSchemeHandler`(M8の
    /// `cid:`画像解決) は `WKURLSchemeTask` 経由で**非同期に** (添付テーブル
    /// の GRDB 検索、未ダウンロードなら IMAP 経由のオンデマンド取得まで
    /// 発生しうる) レスポンスを返す実装になっており、実機では `didFinish`
    /// がこの非同期解決の完了を待たずに発火することがある — 修正前は
    /// それを見越して「`didFinish` 直後に1回 + 0.3秒後にもう1回」という
    /// 固定ウェイトの決め打ちでカバーしていたが、0.3秒より遅い画像解決
    /// (低速回線・未キャッシュの添付ダウンロード等) では両方とも実際の
    /// レイアウトが確定する前に測定してしまい、その時点の (実際より小さい)
    /// `naturalHeight` を元に `outer.style.height` を確定させてしまって
    /// いた。scale が必要なケース (`naturalWidth > viewportWidth`) では
    /// この `outer.style.height` が明示的な固定値になるため、あとから画像
    /// が読み込まれてページの実際の高さが伸びても反映されず、ページ末尾
    /// (画像より下の段落・ボタン等) が `overflow: hidden` の外側に押し
    /// 出されたまま見えなくなる — 「罫線の下から本文が描画されない」実機
    /// 報告と一致する。
    ///
    /// 修正: `document.images` のうち `complete === false` なもの全てに
    /// ついて `load`/`error` イベント (どちらであっても「この画像の分の
    /// レイアウトは確定した」ことを意味する) を待つ `Promise` を返す
    /// non-async IIFE にした — `evaluateJavaScript` (Swift の `async` 版)
    /// はページが返した `Promise` の解決を実際に待つ (WebKit の標準
    /// 挙動)。画像1枚あたり 4,000ms (4秒) のタイムアウトも
    /// 持たせてある — ブロックされたリモート画像・失敗した `cid:` 解決が
    /// 永久に `load`/`error` のどちらも発火しないケースへの安全網
    /// (`WKContentRuleList` でブロックされたリクエストは通常 `error` を
    /// 発火するはずだが、「はず」に全面的に頼らない)。
    /// Task #51: the dark-mode "反転" decision, made here (not statically
    /// in `HTMLDocumentBuilder`) — see `HTMLDocumentBuilder.wrap(bodyHTML:
    /// autoAdjustColorsInDarkMode:)`'s doc comment for why a static
    /// "does the mail declare its own dark support" check alone regressed
    /// (it invert()ed messages with zero author color declarations too,
    /// wrongly flipping their already-correct auto-adapted `CanvasText`
    /// into unreadable dark-on-transparent). Runs as part of the same
    /// `fitToWidthScript` IIFE (after `waitForImages()`, before `fit()`)
    /// rather than as a separate `evaluateJavaScript` call — cheap, keeps
    /// every call site (`didFinish`, the 1.5s safety net,
    /// `HTMLTranslationController`'s post-mutation reapply) automatically
    /// covered without threading a new parameter through all of them, and
    /// `document.getElementById('otegami-fit-outer').hasAttribute
    /// ('data-otegami-invert-check')` (set only when `HTMLDocumentBuilder
    /// .wrap` decided this document is even eligible — setting OFF or the
    /// mail declaring its own dark support both mean the attribute is
    /// absent) makes the whole thing self-contained: no Swift-side state
    /// needs to travel alongside `webView` across those different call
    /// sites. Skipped entirely outside dark mode (`matchMedia`) since the
    /// CSS itself is `@media (prefers-color-scheme: dark)`-scoped anyway —
    /// running the DOM walk in light mode would just be wasted work.
    ///
    /// Measures, in priority order, the first *opaque* (alpha > 0)
    /// `background-color` among: `document.body` itself (a message's own
    /// `<style>body{...}</style>` rule — preserved verbatim by
    /// `HTMLDocumentBuilder.extractHeadStyles` into this document's own
    /// `<head>` — legitimately targets this real `<body>` tag, so this
    /// catches the extremely common "page background" declaration even
    /// though the original `<body ...>` tag's own attributes/inline style
    /// don't survive `extractBodyContent` at all), `#otegami-fit-inner`
    /// (the wrapper itself), then the largest-on-screen-area element
    /// anywhere inside it that sets one explicitly (a "card" `<div>` etc.
    /// — capped to the first 800 elements purely as a cheap safety net
    /// against a pathological document, not expected to matter for real
    /// mail) **and covering at least 30% of `inner`'s own rendered area**
    /// (Task #84 — see `findEffectiveBackground`'s own inline comment for
    /// the real-device case this guards against: a small colored CTA
    /// button being the *only* element with any background at all,
    /// trivially "winning" as the largest candidate despite covering a
    /// sliver of the message). A message with zero color declarations
    /// anywhere (today's regression case) never finds an opaque candidate
    /// at any of the three tiers — this file's own reset already sets
    /// `background: transparent` on `html, body`, and nothing else in the
    /// document overrides it — so `findEffectiveBackground` returns `null`
    /// and `decideDarkInversion` leaves `.otegami-invert-for-dark` off
    /// (the safe default for "couldn't determine").
    ///
    /// Only when an opaque background *is* found and its WCAG relative
    /// luminance is above 0.5 (i.e. it reads as a light background — a
    /// message written light-mode-only) does this add the class. A
    /// handful (`<= 6`) of representative text nodes' `color` are also
    /// sampled as a light corroborating signal (skipped, not blocking,
    /// when text sampling itself comes back empty — a background that's
    /// genuinely measured as light is reason enough on its own to invert).
    ///
    /// **Task #80**: everything above still decides *whether* a message
    /// needs help ("intervene" — `shouldIntervene` in `decideDarkInversion`
    /// below); what changed is *which* remedy gets applied once that's
    /// true. `outer.hasAttribute('data-otegami-prefer-invert')` (set by
    /// `HTMLDocumentBuilder.wrap` only when `autoAdjustColorsInDarkMode` is
    /// `true` — now an opt-in, default `false`) picks classic invert
    /// (`.otegami-invert-for-dark`/`.otegami-invert-active`, unchanged from
    /// Task #51/#56/#71) when present; the new default (attribute absent)
    /// picks "keep light" (`.otegami-keep-light-active`) instead — the
    /// message's own light colors render untouched (no filter, no logo-chip
    /// treatment needed) while a small CSS safety net
    /// (`HTMLDocumentBuilder.wrap`'s `darkModeInvertStyle`, the
    /// `otegami-keep-light-active` rule) forces `html`/`body` to a white
    /// canvas so nothing shows through any gap the message's own styling
    /// doesn't cover. This directly answers the real-device report (video
    /// f012→f015) that the invert path's "flash correct-light, then flip to
    /// inverted-dark" transition, plus its own artifacts (Task #71's white
    /// stripe/logo-sinking), were worse than just leaving a light-designed
    /// message light. A message with no color declarations at all still
    /// never reaches `shouldIntervene = true` (this section's existing
    /// reasoning, unchanged), so it keeps rendering dark-native via
    /// `CanvasText` regardless of this setting either way.
    ///
    /// **Task #98 (実機フィードバック: Google カレンダー招待メール等がダーク
    /// モードでほぼ読めない)**: 背景が最後まで解決しない (`findEffectiveBackground`
    /// が`null`) ケースの`representativeTextLuminance`によるフォールバック
    /// (直前の段落、Task #56) は文書順で見つかった最初の6テキストノードしか
    /// 平均しない — 実際の招待メールは本文の主要ラベル ("会議のリンク"/
    /// "日時"/"ゲスト"、白背景前提の`#5f6368`等の中間グレーを明示指定) に
    /// 届く前に、非表示のプレビュー用テキストや色を明示しない見出しなど
    /// (著者が色を指定していないので `CanvasText` 経由でダークモード中は
    /// 明るく解決される) を複数拾ってしまい、6件の平均が0.5を超えて
    /// 「介入不要」に転ぶことがあった (実測で確認済み)。`explicitDarkText
    /// IsMajority`はこの取りこぼしを拾う追加の証拠 — 6件のサンプリングでは
    /// なく`inner`配下の**全テキストノード**を文字数ベースで集計し、
    /// 「祖先のいずれかが明示的に`color`を指定している」サブツリー配下の
    /// テキストだけを対象に、その実測輝度 (閾値 0.55、
    /// `representativeTextLuminance`の0.5よりわずかに緩い — 白背景前提の
    /// 中間色まで拾うため) が低いものの文字数が可視テキスト全体の過半を
    /// 占めるかどうかを見る。色を一切指定しない (継承のみの) テキストは
    /// 明示指定側にカウントしない — プレーンテキスト風メールを誤って
    /// 白カード化しないための線引き。既存の6サンプル判定 (`shouldIntervene`
    /// が既に`true`) はそのまま優先し、この追加判定は「介入不要」に転んだ
    /// ときの二段目のフォールバックとしてだけ働く。
    ///
    /// **Task #104 (実機フィードバック: Readdle Documents のニュースレター等
    /// が上記 Task #98 の対策後もダークネイティブのまま読めない)**: 直前の
    /// 段落の「明示的に`color`を指定」の判定方法をここで拡張した —
    /// リリース当初 (Task #98) は「祖先のいずれかがインライン`style`で
    /// `color`を指定」だけを見ており、`<style>`ブロックの CSS クラス経由で
    /// 文字色を指定するニュースレター (インライン style を使わず
    /// `.body-text { color: #5f6368; }` のようなクラスセレクタで配色する
    /// テンプレートは珍しくない) を取りこぼしていた。
    /// `collectExplicitColorSelectors`が`document.styleSheets`
    /// (`HTMLDocumentBuilder.wrap`が注入する自前の`<style>`は
    /// `data-otegami-base-style`属性で除外し、メール自身が持っていた
    /// `<style>`ブロックだけを見る) を走査して`color`宣言を持つセレクタを
    /// 集め、`nearestExplicitColorAncestor`が`Element.matches()`で祖先を
    /// マッチさせる — インライン`style`の判定と同じ経路に合流させることで、
    /// どちらの書き方でも同じ実測輝度ベースの判定を通る。詳細は
    /// `docs/design-system.md`のTask #98節 (このTask #104の追記含む) 参照。
    private static let fitToWidthScript: String = {
        guard let url = Bundle.main.url(forResource: "html-fit-to-width", withExtension: "js") else {
            preconditionFailure("html-fit-to-width.js is missing from the app bundle")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            preconditionFailure("Failed to load html-fit-to-width.js: \(error)")
        }
    }()

    /// Task #58 diagnostic instrumentation (temporary): reads back whatever
    /// `fitToWidthScript` stashed into `data-otegami-diag` — see that
    /// script's doc comment for why this indirection (rather than just
    /// returning the value from `fitToWidthScript` itself) is needed on this
    /// toolchain. Plain and synchronous (no `Promise`), which is what makes
    /// this one actually bridge back through `evaluateJavaScript`.
    private static let readDiagScript = "document.documentElement.getAttribute('data-otegami-diag');"

    /// Task #58 diagnostic instrumentation (temporary): logs whatever
    /// `readDiagScript` reads back via `Logger` so a `simctl spawn ... log
    /// show` capture during a real-device-style repro shows the exact
    /// numbers `fit()` measured — see `fitToWidthScript`'s doc comment for
    /// what each field means. Removed once Task #58's root cause is
    /// confirmed and fixed.
    private static let diagnosticLogger = Logger(subsystem: "com.mtkg.otegami", category: "HTMLHeightDiagnostic")

    /// Task #58 (根治): the `WKScriptMessageHandler` name `fitToWidthScript`'s
    /// `postHeight()` posts to — registered on `webView.configuration
    /// .userContentController` by both `HTMLWebViewRepresentable.makeUIView`/
    /// `makeNSView`. A message handler is a separate, independent channel
    /// from `evaluateJavaScript`'s own return-value bridging (the thing
    /// that's broken for Promise-resolved values on this toolchain — see
    /// `fitToWidthScript`'s doc comment) — confirmed reliable in this same
    /// investigation, which is why the actual fix uses it instead of trying
    /// to work around the return-value bug.
    static let heightMessageHandlerName = "otegamiHeight"

    static func applyFitToWidth(to webView: WKWebView) {
        // Task #80 (チラつき根絶): `fitToWidthScript` is an IIFE that
        // returns a `Promise` (`waitForImages().then(...)`, doc comment
        // above `fitToWidthScript` covers why) — `evaluateJavaScript(_:
        // completionHandler:)` genuinely waits for that promise to settle
        // before invoking its completion handler, exactly the behavior this
        // reveal needs: by the time this closure runs, `decideDarkInversion()`
        // has already decided "keep light" / "invert" / "do nothing" *and*
        // `fit()`/`postHeight()` have already run, so revealing here can
        // never show a frame that's still mid-decision. The completion
        // handler still fires (with an error) even though bridging the
        // resolved value itself is broken on this toolchain (this same
        // method's diagnostic `Task` below documents that bug) — this
        // reveal only cares that the closure *ran*, never about `error` or
        // the (discarded) result, so that bug doesn't affect it.
        webView.evaluateJavaScript(fitToWidthScript) { [weak webView] _, _ in
            guard let webView else { return }
            revealIfNeeded(webView)
        }
        // Task #58 diagnostic instrumentation (temporary) — see
        // `readDiagScript`'s doc comment. A short fixed delay (not a retry
        // loop) is good enough here: this whole call is diagnostics-only,
        // triggered from a controlled repro, not something that needs to be
        // robust against arbitrary timing the way the real fit-to-width path
        // does.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            do {
                let result = try await webView.evaluateJavaScript(readDiagScript)
                diagnosticLogger.notice("fitToWidth diag: \(String(describing: result), privacy: .public); webView.bounds=\(String(describing: webView.bounds), privacy: .public); webView.frame=\(String(describing: webView.frame), privacy: .public)")
            } catch {
                diagnosticLogger.error("fitToWidth diag read failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Task #80 (チラつき根絶): reveals `webView` (`HTMLWebViewRepresentable
    /// .makeUIView`/`makeNSView` sets `alpha`/`alphaValue = 0` right after
    /// creating it) with a short fade — called every time `applyFitToWidth`'s
    /// promise settles (initial `didFinish`, the 1.5s safety net, and 1i's
    /// post-mutation reapply via `HTMLTranslationController`), not just
    /// once: the `alpha < 1` guard makes every call after the first a cheap,
    /// harmless no-op, so there's no need to track "have we revealed yet"
    /// as separate state. Also called from `didFail`/`didFailProvisionalNavigation`
    /// below as a safety net for the case `didFinish` never fires at all
    /// (a real navigation failure) — this view must never stay permanently
    /// invisible.
    private static func revealIfNeeded(_ webView: WKWebView) {
        #if os(iOS)
        guard webView.alpha < 1 else { return }
        UIView.animate(withDuration: 0.15) { webView.alpha = 1 }
        #elseif os(macOS)
        guard webView.alphaValue < 1 else { return }
        webView.animator().alphaValue = 1
        #endif
    }

    /// `WKNavigationDelegate`'s "load finished" callback — fires once per
    /// `loadHTMLString(_:baseURL:)` call (`load(html:...)` above), the only
    /// kind of navigation this app's own code ever initiates (a stray tapped-
    /// link navigation never reaches `didFinish` as a *successful* main-
    /// frame load in the way that matters here, since `decidePolicyFor`
    /// cancels it first). A single call is enough now that `fitToWidthScript`
    /// itself awaits every still-loading `<img>` before measuring (see its
    /// doc comment) — the previous "run once immediately, run again after a
    /// blind 0.3s" pair was papering over exactly that race without actually
    /// closing it. One more delayed call is kept purely as a cheap safety
    /// net for layout settling unrelated to image loads (e.g. web fonts,
    /// though this app doesn't currently inject any) — not expected to
    /// change the result in the common case.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Self.applyFitToWidth(to: webView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak webView] in
            guard let webView else { return }
            Self.applyFitToWidth(to: webView)
        }
    }

    /// Task #80 (チラつき根絶) safety net: `applyFitToWidth`'s reveal only
    /// ever fires once `didFinish` actually happens — a genuine navigation
    /// failure (rare for this app's own trusted `loadHTMLString`, but not
    /// impossible) would otherwise leave the web view permanently hidden at
    /// `alpha`/`alphaValue == 0` with no further callback ever arriving to
    /// undo that. Revealing here regardless of what actually failed to load
    /// is the right call — showing whatever partial/blank content resulted
    /// is strictly better than an invisible message view a user can't tell
    /// apart from "still loading" forever.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.revealIfNeeded(webView)
    }

    /// Task #80 — see `didFail(navigation:withError:)` just above; same
    /// reasoning, the other WebKit failure callback shape.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Self.revealIfNeeded(webView)
    }

    /// Decides every navigation this web view ever sees — main frame and
    /// subframe alike. **Deliberately does not branch on
    /// `navigationAction.navigationType`, and never allows a main-frame
    /// navigation through this method at all** — two real-simulator
    /// findings building C7 forced both departures from a more "obvious"
    /// implementation:
    ///
    /// 1. The original implementation allowed exactly `.other`-typed
    ///    navigations, on the assumption that's what the trusted initial
    ///    `loadHTMLString(_:baseURL:)` call is classified as. A synthesized
    ///    tap on a plain `<a href="https://...">` link turned out to *also*
    ///    reach this method with a main-frame navigation that got allowed
    ///    through — confirmed by screenshot: the tapped link's page loaded
    ///    in place inside this same `WKWebView`.
    /// 2. Tracking "is a programmatic load outstanding" with a flag set
    ///    right before every `loadHTMLString` call (an earlier attempt at
    ///    fixing this) didn't help either, and pointed at the real
    ///    explanation: `loadHTMLString(_:baseURL:)` apparently **never
    ///    reaches `decidePolicyFor` at all** in this WebKit version — it's
    ///    not a real `URLRequest`-backed navigation, so there's nothing for
    ///    the navigation-policy pipeline to decide. The flag was therefore
    ///    never consumed by the load it was meant to guard, and sat `true`
    ///    until the *next* navigation — the link tap — consumed it instead
    ///    and got waved through as if it were the trusted load.
    ///
    /// Given `loadHTMLString` itself never shows up here, the correct rule
    /// is simply: **no main-frame navigation this method ever sees is the
    /// initial render** — every one is something else (a link tap, a
    /// redirect, ...) and gets cancelled unconditionally, forwarding
    /// `http`/`https` targets to `onOpenLink` (C7's browser choice).
    ///
    /// Subframe navigations (`targetFrame?.isMainFrame == false` — e.g. an
    /// `<iframe src>`'s own declarative load) are allowed through
    /// unconditionally: whether that resource actually loads is entirely
    /// gated by the `WKContentRuleList` (`applyContentRuleList`, keyed to
    /// `allowsExternalContent`) at the network level, independent of this
    /// method — same "外部画像ブロックとは独立に動く" design already documented
    /// for `cid:` images. JavaScript stays disabled webview-wide
    /// (`allowsContentJavaScript = false` on `defaultWebpagePreferences`)
    /// regardless of any of this, so an allowed subframe navigation still
    /// can't execute script.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if !isMainFrame {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            onOpenLink(url)
        }
    }
}

/// Task #58 (根治): receives the real content height `fitToWidthScript`'s
/// `postHeight()` posts to `HTMLWebViewCoordinator.heightMessageHandlerName`.
/// `message.body` is whatever JSON-compatible value `postMessage` was
/// called with — a plain JS number bridges to `NSNumber` here (unlike the
/// Promise-return-value bridging bug `fitToWidthScript`'s doc comment
/// documents; this is an entirely different WebKit code path and isn't
/// affected by it).
extension HTMLWebViewCoordinator: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.heightMessageHandlerName, let height = (message.body as? NSNumber)?.doubleValue, height.isFinite, height > 0 else { return }
        onHeightChange(CGFloat(height))
    }
}

extension HTMLWebViewCoordinator: WKUIDelegate {
    /// C7 バグ修正 (リンクがブラウザで開かない):
    /// `target="_blank"`／`rel="noopener"`のような「新しいウィンドウ/タブで
    /// 開く」リンクは、`navigationAction.targetFrame`が`nil`になる —
    /// `decidePolicyFor`の`isMainFrame`判定は`navigationAction.targetFrame?
    /// .isMainFrame ?? true`なので理屈の上ではこの`nil`ケースも「メイン
    /// フレーム扱い」でキャンセルされ`onOpenLink`に回るはずだが、この
    /// WebKitバージョン/実機でその通りに動く保証はない —
    /// `loadHTMLString`が`decidePolicyFor`に一切現れないという、この
    /// ファイルの別の実測済みの驚き (同メソッドのdoc comment) が示すとおり、
    /// このAPIの実際の挙動は文書化された仕様と食い違うことがある。
    /// `WKUIDelegate`を一切実装していなかった (=`webView.uiDelegate`が
    /// `nil`のまま) 場合、新しいウィンドウを要求するナビゲーションが
    /// `decidePolicyFor`を素通りしてここへ来ると、行き先がなく黙って
    /// 何も起きない — メールの「アプリで見る」「配信停止はこちら」等、
    /// 実際のメールに頻出する`target="_blank"`リンクがまさにこのパターン。
    /// このメソッド自体は新しい`WKWebView`を一切作らず (常に`nil`を返す)、
    /// 対象URLを`decidePolicyFor`と全く同じ経路 (`onOpenLink`) に渡すだけ —
    /// 「新しいウィンドウでHTMLを表示する」ためのUI自体をこのアプリは持たない
    /// (リンクは常にブラウザ側で開く) ので、これで十分。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            onOpenLink(url)
        }
        return nil
    }
}
