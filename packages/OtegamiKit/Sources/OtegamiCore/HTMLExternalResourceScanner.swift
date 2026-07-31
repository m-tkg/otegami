import Foundation

/// Detects whether an HTML message body references any external
/// (`http`/`https`) resource — images, background images, iframes, ...
/// Used by the app's `HTMLMessageView` (M2) to decide whether to show a
/// "画像を表示" banner *before* ever loading the content into a `WKWebView`.
///
/// This is a text-level heuristic, not a real HTML/CSS parser: `WKWebView`
/// itself (via a `WKContentRuleList`) is what actually blocks the network
/// requests, so a false positive here only costs an unnecessary banner and
/// a false negative only costs a missing one — neither is a security
/// issue, so a regex scan is a deliberate simplicity/robustness tradeoff
/// over hand-writing an HTML tokenizer just to answer this one question.
public enum HTMLExternalResourceScanner {
    private static let pattern = #"(?i)(?:src|href|background|poster)\s*=\s*["']\s*https?://|url\(\s*["']?\s*https?://"#

    public static func containsExternalResource(html: String) -> Bool {
        html.range(of: pattern, options: .regularExpression) != nil
    }

    /// Task #207 (ユーザー要望「(平文httpの画像を)許可する方針でいいが、確認
    /// ダイアログは出してほしい」): `containsExternalResource`とは別の、
    /// 意図的に狭い判定 — 平文 `http://`(`https`は対象外)の**画像相当**の
    /// 参照だけを見る。`containsExternalResource`が`href`(リンク)も含めて
    /// 広く拾うのは「画像を表示」バナーの既存の設計(多少の過検知は許容 —
    /// 同enumのdoc comment参照) だが、この関数は「http の画像があるけど
    /// いい?」という確認ダイアログの表示可否そのものを左右するので、
    /// リンクしか無いメール (`<a href="http://...">`) で誤って画像の確認
    /// ダイアログを出さないよう`href`を対象から外し、画像を実際に読み込み
    /// うる属性 (`src`/`background`/`poster`) と CSS の `background-image:
    /// url(...)` だけに絞った。`https://`は「http」を含むが直後が`s`なので
    /// この`http://`(sなし)パターンには一致しない — 否定先読みは不要。
    private static let plaintextHTTPImagePattern = #"(?i)(?:src|background|poster)\s*=\s*["']\s*http://|url\(\s*["']?\s*http://"#

    public static func containsPlaintextHTTPImage(html: String) -> Bool {
        html.range(of: plaintextHTTPImagePattern, options: .regularExpression) != nil
    }
}
