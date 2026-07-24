import Foundation

/// Rewrites `cid:` references in an HTML message body (M8) to the app's
/// custom `otegami-cid://` URL scheme, which `HTMLMessageView`'s
/// `WKURLSchemeHandler` resolves against the `attachment` table's
/// `contentId` column. A text-level regex rewrite rather than a real
/// HTML/CSS parser — the same "simplicity/robustness tradeoff" already
/// documented on `HTMLExternalResourceScanner` (a false negative here just
/// means one inline image doesn't load; not a security issue, since
/// `WKContentRuleList` is what actually enforces the external-resource
/// block, and `otegami-cid://` is a scheme the rule list never matches
/// regardless of what this rewrite does or doesn't catch).
///
/// Only rewrites `src="cid:..."`/`src='cid:...'` — `Content-ID`-referenced
/// images are always delivered via an `<img src="cid:...">` in practice
/// (RFC 2392); CSS `url(cid:...)` backgrounds are out of scope, same as
/// `HTMLExternalResourceScanner` not scanning inline `style=` attributes
/// for `url(https://...)`.
public enum CIDURLRewriter {
    private static let regex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(?i)(src)\s*=\s*(["'])cid:([^"']+)\2"#
        )
    }()

    public static func rewrite(html: String) -> String {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.stringByReplacingMatches(
            in: html,
            range: range,
            withTemplate: "$1=$2\(Self.scheme)://$3$2"
        )
    }

    /// The custom `WKURLSchemeHandler` scheme this rewrite targets. Kept
    /// here (not duplicated as a string literal in `HTMLMessageView`) so
    /// the rewrite and the handler that resolves it can never drift apart.
    public static let scheme = "otegami-cid"
}
