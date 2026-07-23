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
}
