import Foundation

/// Task #42, point 4「BIMI 対応」— **セキュリティ必須**の安全性ゲート:
/// a BIMI logo SVG comes from an arbitrary DNS TXT record + arbitrary HTTPS
/// URL an email sender's domain controls — it is attacker-influenced input
/// exactly like any other part of a hostile email, so it must be validated
/// before this app renders a single pixel of it, not merely before treating
/// it as "trusted brand content". `isSafe(_:)` fails **closed**: anything it
/// doesn't specifically recognize as safe gets rejected, and a rejected SVG
/// means `CompanyLogoAvatarResolver` falls back to favicon (or, failing
/// that, the initials avatar) rather than rendering nothing-in-particular.
///
/// BIMI's own spec (the "SVG Tiny Portable/Secure" profile) already
/// mandates most of what this checks — no scripting, no external
/// references, no raster images, no interactivity — so a spec-compliant
/// BIMI logo should pass every one of these checks trivially. This
/// validator exists because **compliance with the spec is not something
/// this app can verify out-of-band** — a malicious or merely careless
/// domain owner could publish a non-compliant SVG, and nothing stops that
/// at the DNS/HTTP layer.
public enum BIMISVGSafety {
    /// Hard size cap, checked before any parsing — an oversized "SVG" is
    /// rejected outright regardless of content (avoids parsing arbitrarily
    /// large attacker-controlled input at all, and matches this batch's
    /// instructions).
    public static let maxByteSize = 64 * 1024

    /// - Returns: `true` only if `data` is UTF-8-decodable text, within
    ///   `maxByteSize`, and contains none of the disallowed constructs below.
    ///   **Does not** validate that the content is well-formed SVG — that's
    ///   `BIMISVGParser`'s job, which independently fails closed on anything
    ///   it doesn't understand. This function only rules out the
    ///   specifically *dangerous* shapes; a safe-but-unparseable SVG still
    ///   passes here and is rejected later, one layer up, by the parser.
    public static func isSafe(_ data: Data) -> Bool {
        guard data.count > 0, data.count <= maxByteSize else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lowered = text.lowercased()

        // No scripting of any kind — the single most important rejection.
        // Covers `<script>`, `javascript:` URIs anywhere (an `href`/`xlink:href`/
        // `fill`/`action` value), and the numerous `on*="..."` event-handler
        // attributes (onload, onclick, onerror, onmouseover, ...).
        if lowered.contains("<script") { return false }
        if lowered.contains("javascript:") { return false }
        if Self.containsEventHandlerAttribute(lowered) { return false }

        // No embedding other documents/content that could itself carry
        // scripting or exfiltrate data on load: raster images, iframes,
        // foreign (non-SVG) content, and `<style>` (BIMI's Tiny-PS profile
        // has no use for CSS anyway — `BIMISVGParser` doesn't support it, so
        // rejecting it here is no loss of legitimate fidelity).
        if lowered.contains("<image") { return false }
        if lowered.contains("<iframe") { return false }
        if lowered.contains("<foreignobject") { return false }
        if lowered.contains("<style") { return false }
        if lowered.contains("<![cdata[") { return false }

        // No external references of any kind (`href`/`xlink:href` not
        // pointing at an in-document `#fragment`) — an `<a>`, `<use>`, or
        // gradient/pattern `href` that fetches something over the network
        // is both a privacy leak (the fetch happens whenever this app draws
        // the sender's avatar, not on any user action) and a potential
        // further attack surface this app has no reason to accept for what
        // is supposed to be a small self-contained brand mark.
        if Self.containsExternalReference(lowered) { return false }

        // XXE-style external entity declarations in a DOCTYPE.
        if lowered.contains("<!doctype"), lowered.contains("entity") { return false }
        if lowered.contains("<!entity") { return false }

        return true
    }

    /// Matches `on` immediately followed by one or more letters, then
    /// (optional whitespace) `=` — i.e. an attribute name shaped like an
    /// event handler (`onload=`, `onclick =`, ...). Deliberately broad (a
    /// false positive here just means a legitimate-but-oddly-named
    /// attribute gets rejected, falling back to favicon — an acceptable
    /// trade-off for a security gate) rather than trying to enumerate every
    /// SVG/DOM event name.
    private static func containsEventHandlerAttribute(_ lowered: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"\bon[a-z]+\s*="#) else { return true }
        let range = NSRange(lowered.startIndex..., in: lowered)
        return regex.firstMatch(in: lowered, range: range) != nil
    }

    /// `true` if any `href="..."` or `xlink:href="..."` attribute value
    /// doesn't start with `#` (an intra-document fragment reference, the
    /// only form this app's renderer needs and the only form BIMI's Tiny-PS
    /// profile's internal `<use>`/gradient-reuse patterns require).
    private static func containsExternalReference(_ lowered: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"(?:xlink:href|href)\s*=\s*"([^"]*)""#) else { return true }
        let range = NSRange(lowered.startIndex..., in: lowered)
        let matches = regex.matches(in: lowered, range: range)
        for match in matches {
            guard match.numberOfRanges > 1, let valueRange = Range(match.range(at: 1), in: lowered) else { continue }
            let value = lowered[valueRange].trimmingCharacters(in: .whitespaces)
            if !value.hasPrefix("#") { return true }
        }
        return false
    }
}
