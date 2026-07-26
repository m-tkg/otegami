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

    /// A real-world `Content-ID` almost always contains an `@` (RFC 2392's
    /// `msg-id`-derived syntax: `<unique-part@domain>`), and `URL`'s host
    /// parser treats an unencoded `@` inside `scheme://<here>` as the
    /// userinfo separator, silently truncating `host` down to whatever
    /// follows it (`URL(string: "otegami-cid://logo@x.test")?.host ==
    /// "x.test"`, dropping `"logo"` entirely) — confirmed with a `swift`
    /// REPL check against this project's deployment target. Percent-encoding
    /// the content id with `CharacterSet.urlHostAllowed` before it goes into
    /// the rewritten URL keeps `@` (and anything else outside that allowed
    /// set) literal instead of structural; `URL.host` on this deployment
    /// target (iOS/macOS 26) percent-*decodes* on read, so
    /// `CIDSchemeHandler.contentId(from:)` gets the original content id back
    /// unchanged with no decoding step of its own required — verified with
    /// the same REPL check (`.host` on an encoded `%40` URL already reads
    /// back as `"@"`).
    public static func rewrite(html: String) -> String {
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !matches.isEmpty else { return html }

        let result = NSMutableString(string: html)
        // Replace back-to-front so earlier matches' NSRanges (computed
        // against the original `html`) stay valid as later ones shift the
        // string's length.
        for match in matches.reversed() {
            let attr = nsHTML.substring(with: match.range(at: 1))
            let quote = nsHTML.substring(with: match.range(at: 2))
            let contentId = nsHTML.substring(with: match.range(at: 3))
            let encodedContentId = contentId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? contentId
            result.replaceCharacters(
                in: match.range(at: 0),
                with: "\(attr)=\(quote)\(Self.scheme)://\(encodedContentId)\(quote)"
            )
        }
        return result as String
    }

    /// B5: whether `html` references any `cid:` inline image at all —
    /// `HTMLMessageView` uses this (the same way `HTMLExternalResourceScanner
    /// .containsExternalResource` gates the remote-image banner) to decide
    /// whether to show the "埋め込み画像を表示" banner *before* ever loading
    /// the content into a `WKWebView`. Reuses `regex` rather than just
    /// calling `rewrite(html:) != html`, so a caller that only wants the
    /// yes/no answer (not the rewritten string) doesn't pay for building one.
    public static func containsCIDReference(html: String) -> Bool {
        let nsHTML = html as NSString
        return regex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)) != nil
    }

    /// The custom `WKURLSchemeHandler` scheme this rewrite targets. Kept
    /// here (not duplicated as a string literal in `HTMLMessageView`) so
    /// the rewrite and the handler that resolves it can never drift apart.
    public static let scheme = "otegami-cid"
}
