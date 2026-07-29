import Foundation

/// Whether a URL is safe to hand to an in-app browser sheet
/// (`SFSafariViewController` on iOS).
///
/// Task #166 (SEC-A, finding F17 of `CLAUDE-SECURITY-RESULTS.md`):
/// `MessageView`'s plain-text body links come from running
/// `NSDataDetector` over an untrusted, attacker-controlled message body —
/// it detects more than http(s) links (e.g. a bare email address becomes
/// a `mailto:` URL). `SFSafariViewController` is documented to accept only
/// http/https and throws on `init` for anything else, so a single
/// attacker-controlled body line containing e.g. a bare email address
/// could crash the app on tap when "アプリ内ブラウザ" is the selected link
/// behavior. `HTMLMessageView.handleLinkTap` already gated on this same
/// check inline before this fix; pulled out here (rather than left
/// duplicated inline in `MessageView`'s `OpenURLAction` closure) so it's
/// covered by `swift test` (`make test`) — `apps/Otegami` has no unit
/// test target (only XCUITest, which needs a simulator), the same reason
/// `MessageSourceFilename`/`AttachmentFilename` live here rather than
/// alongside the app-side views that call them.
public enum InAppBrowserURLPolicy {
    /// `true` only for `http`/`https` (case-insensitive) — every other
    /// scheme (`mailto:`, `tel:`, a bare/malformed URL with no scheme,
    /// ...) is not supported by `SFSafariViewController` and should fall
    /// through to the system default handler instead.
    public static func isSupported(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
