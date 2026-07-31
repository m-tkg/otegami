import Foundation
import WebKit
import os

/// 1i「HTMLメールもレイアウトを保持したまま翻訳」(実機フィードバック
/// 「htmlメールの場合、レイアウトをなるべく崩さないように翻訳を表示して
/// 欲しい」): the handle `HTMLMessageView` vends to `MessageView` (via
/// `onTranslationControllerReady`) so translation — which needs
/// `AppEnvironment.messageTranslator`, firmly `MessageView`'s
/// responsibility, and has no business knowing about `WKWebView` — can
/// still collect and rewrite the live web view's DOM text nodes without
/// `MessageView` ever importing `WebKit` itself. `HTMLDocumentBuilder.wrap
/// (bodyHTML:)`'s "fit-to-width" doc comment already explains why a host-
/// initiated `evaluateJavaScript` call works fine even though page-authored
/// script is disabled (`allowsContentJavaScript = false`) — this reuses the
/// exact same mechanism for a different purpose.
///
/// Every extracted/rewritten text node is wrapped in a `<span data-otegami-
/// i="N">` the first time any of these methods sees it — `data-otegami-i`
/// gives each node a stable handle across the several separate JS round
/// trips this feature needs (collect → translate (async, off the web view
/// entirely — `MessageTranslator` is a plain Swift actor) → write back),
/// `data-otegami-original` preserves the pre-translation text so
/// `showOriginal()` can restore it without asking Swift for it again. Not
/// `@Observable`/`ObservableObject`: nothing reads its properties
/// reactively, it's a purely imperative handle whose methods are called at
/// specific moments (a button tap, `HTMLMessageView`'s `.task(id:)`).
///
/// Every method is a no-op when `webView` is still `nil` (the brief window
/// before `HTMLWebViewRepresentable.makeUIView`/`makeNSView` has run) —
/// `HTMLMessageView`'s `.task(id:)` re-runs on the next relevant state
/// change regardless, so a caller racing view construction just means "try
/// again shortly", not a crash.
@MainActor
final class HTMLTranslationController {
    private weak var webView: WKWebView?

    func attach(to webView: WKWebView) {
        self.webView = webView
    }

    /// The DOM walk every method below shares, as a JS function source
    /// fragment: skips `<script>`/`<style>`/`<title>` and whitespace-only
    /// text, wraps each qualifying (or reuses each already-wrapped) text
    /// node in a stamped `<span>`, and calls `onText(span, index)` for each
    /// one in document order — `extractTranslatableTexts`/`applyTranslations`
    /// both embed this and just differ in what their `onText` callback does
    /// with it. Scoped to `#otegami-fit-inner` (`HTMLDocumentBuilder.wrap`'s
    /// fit-to-width wrapper) rather than the whole document — conveniently
    /// already exactly "this message's own rendered content and nothing
    /// else" (this app's fixed CSS reset in `<style>`/`<head>` isn't inside
    /// it, so there's no risk of ever touching that instead). Idempotent by
    /// construction: a node already stamped by an earlier pass (e.g. a
    /// retry after a failed translation, or `applyTranslations` re-running
    /// after `HTMLWebViewCoordinator.load(...)` reloaded the document from
    /// scratch — in which case there's nothing stamped yet, so this
    /// re-wraps from zero) is reused rather than re-wrapped or double-
    /// counted.
    private static let walkAndWrapFunctionSource = """
    function otegamiWalkAndWrap(onText) {
      function shouldSkip(tag) { return tag === 'SCRIPT' || tag === 'STYLE' || tag === 'TITLE'; }
      var index = 0;
      function walk(node) {
        if (node.nodeType === 1) {
          if (shouldSkip(node.tagName)) { return; }
          if (node.hasAttribute && node.hasAttribute('data-otegami-i')) {
            onText(node, Number(node.getAttribute('data-otegami-i')));
            return;
          }
          var children = Array.prototype.slice.call(node.childNodes);
          for (var i = 0; i < children.length; i++) { walk(children[i]); }
          return;
        }
        if (node.nodeType === 3) {
          var text = node.nodeValue;
          if (text && text.trim().length > 0) {
            var span = document.createElement('span');
            span.setAttribute('data-otegami-i', String(index));
            span.setAttribute('data-otegami-original', text);
            node.parentNode.insertBefore(span, node);
            span.appendChild(node);
            onText(span, index);
            index += 1;
          }
        }
      }
      walk(document.getElementById('otegami-fit-inner') || document.body);
    }
    """

    /// Task #61 (実機フィードバック「HTMLメールの翻訳ボタンが無反応」):
    /// `return texts;` (a bare JS array) ではなく `return JSON.stringify
    /// (texts);` (プレーンな文字列) を返す — このプロジェクトのツール
    /// チェーンでは `evaluateJavaScript` の戻り値ブリッジが Promise 解決値
    /// に対して壊れていることが Task #58 で確認済み (`fitToWidthScript`の
    /// doc comment参照) で、この抽出 IIFE 自体は Promise を経由しない同期
    /// 呼び出しなので理論上は影響を受けないはずだが、実機フィードバックが
    /// 「HTMLメールの翻訳だけ無反応」と報告している以上、複雑な値の
    /// ブリッジそのものに実機依存の余地がある可能性を排除できない —
    /// 同じファイルの`readDiagScript`/`fitToWidthScript`の`data-otegami-diag`
    /// 属性が採る「JSON文字列として運び、Swift側でデコードする」という
    /// 実証済みの安全な形に統一しておくことで、この抽出だけが疑わしい
    /// 特別扱いのまま残ることを避ける。
    private static let extractScript = """
    \(walkAndWrapFunctionSource)
    (function () {
      var texts = [];
      otegamiWalkAndWrap(function (span, i) { texts[i] = span.getAttribute('data-otegami-original'); });
      return JSON.stringify(texts);
    })();
    """

    private static let showOriginalScript = """
    (function () {
      var spans = document.querySelectorAll('[data-otegami-i]');
      for (var i = 0; i < spans.length; i++) {
        var original = spans[i].getAttribute('data-otegami-original');
        if (original !== null) { spans[i].textContent = original; }
      }
    })();
    """

    private static let showTranslatedScript = """
    (function () {
      var spans = document.querySelectorAll('[data-otegami-i]');
      for (var i = 0; i < spans.length; i++) {
        var translated = spans[i].getAttribute('data-otegami-translated');
        if (translated !== null) { spans[i].textContent = translated; }
      }
    })();
    """

    /// Task #61 diagnostic/failure logging — separate from `diagnosticLogger`
    /// (Task #58, HTML height) since this covers a different feature; kept
    /// permanent (not marked "temporary") since a JS-bridge failure here is
    /// exactly the kind of real-device-only anomaly this project has
    /// repeatedly needed `simctl spawn ... log stream` to diagnose (Task
    /// #58's own writeup). Only ever logs on an actual failure — no
    /// per-success noise.
    private static let translationLogger = Logger(subsystem: "com.mtkg.otegami", category: "HTMLTranslationDiagnostic")

    /// Collects every visible text node's *current* text, in document
    /// order — the array `MessageView` hands to `MessageTranslator
    /// .translateHTMLTextNodes(messageId:texts:...)`. Read straight from
    /// `data-otegami-original` (not the node's live text, which could
    /// already be showing a translation from an unrelated earlier pass)
    /// so a re-extraction is always the true source text, never a
    /// translation-of-a-translation.
    ///
    /// Task #61 (実機フィードバック「HTMLメールの翻訳ボタンが無反応」):
    /// returns `nil` — not `[]` — when the JS call itself failed
    /// (`evaluateJavaScript` threw, or the result didn't decode as the JSON
    /// array `extractScript` promises) so `MessageView.requestTranslation`
    /// can tell "this message genuinely has no translatable text" (`[]`,
    /// harmless — an image-only mail, say) apart from "extraction broke"
    /// (`nil`) and show a visible failure for the latter instead of quietly
    /// doing nothing, which is what made the original report look like a
    /// dead tap ("無反応") — the translation flow used to press ahead with
    /// an empty `texts` array either way, translating zero paragraphs
    /// "successfully" with no visible effect and no error shown.
    func extractTranslatableTexts() async -> [String]? {
        guard let webView else { return nil }
        // Phase 5続報 (2026-07-30、実機 eml 再現: table レイアウトHTMLで
        // 抽出が0件を返す不具合の調査用): 呼び出し時点で`webView.isLoading`
        // が`true`なら、ページ読み込み完了 (`didFinish`) より先に抽出を
        // 呼んでしまっているレース疑い (`translationController.webView`は
        // `makeUIView`/`makeNSView`でページ読込前にセットされ、`didFinish`
        // を待たない — `MessageView.htmlTranslationController`が
        // non-nilになるタイミングと実際に`#otegami-fit-inner`がDOMに
        // 存在するタイミングは別) の直接証拠になる。本文は一切含めない
        // (F15の趣旨)。
        // `HTMLTranslationController`自体が`@MainActor`なので`webView`
        // への同期アクセスはこのまま安全 (`MainActor.run`は不要)。
        let wasLoading = webView.isLoading
        do {
            let result = try await webView.evaluateJavaScript(Self.extractScript)
            guard let jsonString = result as? String,
                  let data = jsonString.data(using: .utf8),
                  let texts = try? JSONDecoder().decode([String].self, from: data)
            else {
                // F15-adjacent (security scan follow-up, 2026-07-30): when
                // `evaluateJavaScript` succeeds but JSON-decoding still
                // fails, `result` here is the actual JSON string
                // `extractScript` returned — i.e. every extracted mail-body
                // text node, verbatim. Logging that at `.public` would leak
                // real mail content into Console.app/sysdiagnose the same
                // way F15 (`MessageTranslator.swift`) did; dropped to the
                // default `.private` redaction.
                Self.translationLogger.error("extractTranslatableTexts: unexpected result shape \(String(describing: result))")
                return nil
            }
            // Phase 5続報: notice レベル固定 (`docs/verify.md`: debug/info
            // は`log collect`に残らない) — 件数・合計文字数・読込中フラグ
            // だけを記録、本文は含めない。次に「HTML翻訳が失敗する」報告が
            // 来た時、この1行で「抽出自体が0件だったか」「ページ読込中に
            // 呼ばれていたか (レース)」を実機ログから直接判定できる。
            Self.translationLogger.notice("extractTranslatableTexts: count=\(texts.count, privacy: .public) totalChars=\(texts.reduce(0) { $0 + $1.count }, privacy: .public) wasLoading=\(wasLoading, privacy: .public)")
            return texts
        } catch {
            Self.translationLogger.error("extractTranslatableTexts failed: wasLoading=\(wasLoading, privacy: .public) error=\(String(describing: error))")
            return nil
        }
    }

    /// Stamps `translations[i]` onto the node at index `i` as
    /// `data-otegami-translated`, WITHOUT changing what's currently visible
    /// — `showTranslated()` is the one that actually flips text on screen,
    /// so a caller that wants both calls this first, then that. Re-derives
    /// the stamped-node list fresh every time (via the same
    /// `otegamiWalkAndWrap` extraction uses) rather than assuming a
    /// previous call's spans still exist, which is what makes this safe to
    /// call again after `HTMLWebViewCoordinator.load(...)` has reloaded the
    /// document from scratch (an image-blocking banner toggled mid-session
    /// wipes every DOM stamp) — the fresh walk reproduces the identical
    /// ordered node list `translations` was aligned against, since both
    /// derive from the same underlying `html` string via the same
    /// deterministic walk. A count mismatch (a stale cached translation
    /// from a differently-shaped document — see `MessageTranslator
    /// .translateHTMLTextNodes`'s doc comment) leaves whatever nodes are in
    /// range stamped and silently ignores the rest, rather than guessing.
    /// Re-runs `HTMLWebViewCoordinator`'s fit-to-width pass afterward —
    /// translated text is rarely the exact same pixel width as the
    /// original, so the scale computed for the original document can be
    /// stale once it's replaced.
    func applyTranslations(_ translations: [String]) async {
        guard let webView, !translations.isEmpty else { return }
        guard let payload = Self.encodeStringArray(translations) else { return }
        let script = "\(Self.walkAndWrapFunctionSource)\n(function (t) { otegamiWalkAndWrap(function (span, i) { if (i >= 0 && i < t.length) { span.setAttribute('data-otegami-translated', t[i]); } }); })(\(payload));"
        _ = try? await webView.evaluateJavaScript(script)
        Self.applyFitToWidthAfterMutation(to: webView)
    }

    /// Restores every stamped node's pre-translation text — a no-op for any
    /// node with nothing stamped (a document that was never translated in
    /// the first place already shows its original text; nothing to do).
    func showOriginal() async {
        guard let webView else { return }
        _ = try? await webView.evaluateJavaScript(Self.showOriginalScript)
        Self.applyFitToWidthAfterMutation(to: webView)
    }

    /// Flips every stamped node to whatever `applyTranslations` last wrote
    /// for it — a no-op for a node `applyTranslations` was never called for
    /// (nothing translated yet).
    func showTranslated() async {
        guard let webView else { return }
        _ = try? await webView.evaluateJavaScript(Self.showTranslatedScript)
        Self.applyFitToWidthAfterMutation(to: webView)
    }

    /// `HTMLWebViewCoordinator.applyFitToWidth(to:)` is internal so this
    /// controller can invoke it across its dedicated source file. Keep the
    /// cross-type dependency contained in this thin forwarder.
    private static func applyFitToWidthAfterMutation(to webView: WKWebView) {
        HTMLWebViewCoordinator.applyFitToWidth(to: webView)
    }

    /// `JSONSerialization` rather than hand-rolled string escaping — JSON's
    /// array-of-strings syntax is valid JS syntax verbatim, and
    /// `JSONSerialization` already correctly escapes every character JS
    /// string literals need escaped (quotes, backslashes, newlines, ...),
    /// which is what makes it safe to splice `translations` (real message
    /// text — not this app's own trusted source, so it can contain
    /// anything, including characters that would otherwise break out of a
    /// naively-quoted JS string) directly into a script string at all.
    private static func encodeStringArray(_ strings: [String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: strings, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
