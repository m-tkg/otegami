import Foundation

/// Task #48 (デフォルトメールアプリ対応): parses a `mailto:` URI per
/// RFC 6068 into the fields `ComposerView` needs to prefill — `to`/`cc`/
/// `bcc` address lists, `subject`, `body`. A pure function (no UI/Composer
/// dependency) so it's trivially unit-testable and reusable from both the
/// app's `onOpenURL` handler and (if ever needed) a UITest driving
/// `xcrun simctl openurl`.
///
/// Deliberately hand-rolled string parsing rather than `URLComponents` —
/// `URLComponents` is built around hierarchical URLs (scheme://authority/
/// path?query) and `mailto:` is not one (RFC 6068 §2: no `//`, the "path"
/// is a comma-separated address list directly after the scheme colon).
/// `URLComponents(string:)` does happen to parse simple cases, but its
/// behavior around a bare `mailto:addr@example.com` (no `?query`) and
/// percent-encoding within the address list isn't part of any documented
/// contract for a non-hierarchical scheme, so this parses the raw string
/// directly instead of relying on it.
///
/// Tolerant by design (RFC 6068 §5 "should be liberal in what it accepts
/// as hfields"): a malformed percent-escape or an unrecognized hfield
/// (`in-reply-to=`, `keywords=`, ...) is silently dropped rather than
/// failing the whole parse — a hostile or buggy `mailto:` link handed to
/// this app by the OS should never crash it, at worst it opens a Composer
/// missing a field it couldn't make sense of.
public enum MailtoURLParser {
    /// The decoded fields pulled out of a `mailto:` URI. Address lists are
    /// raw `addr-spec` strings (not `EmailAddress` — that's `OtegamiCore`
    /// too, but keeping this type's output free of any assumption about how
    /// the caller wants to parse/validate addresses further keeps this
    /// parser a single-purpose RFC 6068 → strings step).
    public struct Result: Equatable, Sendable {
        public var to: [String]
        public var cc: [String]
        public var bcc: [String]
        public var subject: String
        public var body: String

        public init(to: [String] = [], cc: [String] = [], bcc: [String] = [], subject: String = "", body: String = "") {
            self.to = to
            self.cc = cc
            self.bcc = bcc
            self.subject = subject
            self.body = body
        }
    }

    /// - Returns: `nil` when `url` isn't a `mailto:` URL at all (wrong
    ///   scheme) — the caller should ignore the open entirely in that case.
    ///   A bare `mailto:` with nothing else still returns a (fully empty)
    ///   `Result`, matching RFC 6068's minimal valid form (opens a blank
    ///   compose, same as tapping "作成").
    public static func parse(_ url: URL) -> Result? {
        parse(url.absoluteString)
    }

    public static func parse(_ string: String) -> Result? {
        guard let colonIndex = string.firstIndex(of: ":") else { return nil }
        guard string[string.startIndex..<colonIndex].lowercased() == "mailto" else { return nil }

        var rest = String(string[string.index(after: colonIndex)...])
        // RFC 6068 defines no fragment component, but strip one defensively
        // rather than letting it leak into the last hfield's value if some
        // caller ever hands us a URL with one appended.
        if let hashIndex = rest.firstIndex(of: "#") {
            rest = String(rest[rest.startIndex..<hashIndex])
        }

        let pathPart: Substring
        let queryPart: Substring?
        if let questionIndex = rest.firstIndex(of: "?") {
            pathPart = rest[rest.startIndex..<questionIndex]
            queryPart = rest[rest.index(after: questionIndex)...]
        } else {
            pathPart = rest[rest.startIndex...]
            queryPart = nil
        }

        var to = addressList(from: pathPart)
        var cc: [String] = []
        var bcc: [String] = []
        var subject = ""
        var body = ""

        if let queryPart {
            for pair in queryPart.split(separator: "&", omittingEmptySubsequences: true) {
                let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let rawKey = components.first,
                      let key = decode(rawKey)?.lowercased()
                else { continue }
                let rawValue = components.count > 1 ? components[1] : Substring("")

                switch key {
                case "to": to.append(contentsOf: addressList(from: rawValue))
                case "cc": cc.append(contentsOf: addressList(from: rawValue))
                case "bcc": bcc.append(contentsOf: addressList(from: rawValue))
                // Later occurrences win, matching "last one wins" for a
                // duplicated query key in most URI-consuming code — RFC
                // 6068 doesn't specify a precedence rule for a repeated
                // singular hfield, so this is a reasonable, unsurprising
                // default rather than silently dropping the duplicate.
                case "subject": subject = decode(rawValue) ?? subject
                case "body": body = decode(rawValue) ?? body
                default:
                    // Unsupported hfield (in-reply-to, keywords, a
                    // custom/nonstandard header, ...) — this app has no use
                    // for arbitrary header injection into a compose, so
                    // these are intentionally ignored rather than surfaced.
                    break
                }
            }
        }

        return Result(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
    }

    /// Splits a raw (still percent-encoded) comma-separated address list —
    /// used for both the URI's path component and each of `to`/`cc`/`bcc`'s
    /// query values, which share the same `addr-spec *("," addr-spec)`
    /// grammar (RFC 6068 §2). Comma is the literal (unencoded) delimiter
    /// per the grammar, so splitting happens *before* percent-decoding each
    /// piece — decoding first could turn a percent-encoded `%2C` inside an
    /// address's quoted local-part into a spurious extra delimiter.
    private static func addressList(from raw: Substring) -> [String] {
        raw.split(separator: ",", omittingEmptySubsequences: true).compactMap { piece in
            guard let decoded = decode(piece)?.trimmingCharacters(in: .whitespaces), !decoded.isEmpty else { return nil }
            // Task #167 / F9 (CLAUDE-SECURITY-20260729-134850/
            // CLAUDE-SECURITY-RESULTS.md): `.whitespaces` doesn't include
            // CR/LF, so a `%0D%0A`-encoded piece (e.g.
            // `mailto:bob@example.com%3E%0D%0ARCPT%20TO:%3Cattacker@evil.test`)
            // survives decode()+trim with its embedded newline intact. Left
            // alone, that string would reach `MailCoreSMTPSession
            // .sendMessage`'s `MCOAddress` construction and become a
            // second, attacker-controlled SMTP command line once sent. The
            // transport layer is the authoritative fix (it validates every
            // address regardless of origin, including ones from a
            // server's `ENVELOPE`), but this parser drops the offending
            // piece too — defense in depth, and consistent with this
            // parser's existing "silently drop what it can't make sense
            // of" tolerance for a malformed percent-escape just above.
            guard !containsControlInjection(decoded) else { return nil }
            return decoded
        }
    }

    /// `true` if `value` contains a CR, LF, or NUL anywhere — not just at
    /// the ends (a leading/trailing one would already be gone after
    /// `.trimmingCharacters(in: .whitespaces)`... except `.whitespaces`
    /// itself doesn't cover CR/LF, which is exactly the gap this guards).
    private static func containsControlInjection(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\u{0}" }
    }

    /// `nil` on a malformed percent-escape (e.g. a lone `%` or `%zz`) —
    /// `String.removingPercentEncoding`'s own failure signal — so callers
    /// can drop just that one malformed piece instead of the whole parse.
    private static func decode(_ raw: Substring) -> String? {
        String(raw).removingPercentEncoding
    }
}
