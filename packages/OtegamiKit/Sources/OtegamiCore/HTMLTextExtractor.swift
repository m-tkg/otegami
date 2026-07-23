import Foundation

/// A small, dependency-free HTML→plain-text extractor. Used by
/// `SyncEngine.BodyFetcher` (M2) to derive `messageBody.plainText` for
/// messages whose server-side MIME structure has an HTML part but no
/// `text/plain` alternative — regex-based rather than a real parser
/// (deliberately: this only ever needs to produce a *readable fallback*
/// for search/snippet/plain-text display, not a faithful rendering, so a
/// full HTML parser would be more machinery than the job needs) and pure
/// Swift so it stays usable from `OtegamiCore` (Linux-compatible, no
/// `WebKit`/`NSAttributedString`).
public enum HTMLTextExtractor {
    /// Strips tags/scripts/styles from `html`, turns block-level
    /// boundaries into newlines, and decodes the handful of HTML entities
    /// that show up in the wild. Not a full HTML5 entity table — good
    /// enough for the common named entities plus numeric/hex references.
    public static func plainText(fromHTML html: String) -> String {
        var text = html

        // Drop entire script/style elements (including their content) —
        // otherwise the tag-stripping pass below would leave raw CSS/JS
        // text behind.
        text = replacing(pattern: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", in: text, with: "")

        // Block-level boundaries become newlines so paragraphs/list items
        // don't run together once tags are stripped.
        text = replacing(pattern: "(?i)<br\\s*/?>", in: text, with: "\n")
        text = replacing(pattern: "(?i)</(p|div|li|tr|h[1-6]|blockquote)>", in: text, with: "\n")

        // Everything else: strip the tag, keep the text.
        text = replacing(pattern: "<[^>]+>", in: text, with: "")

        text = decodeEntities(text)

        // Collapse runs of blank lines left behind by the block-boundary
        // substitutions above, and trim.
        text = replacing(pattern: "\\n{3,}", in: text, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
    ]

    private static func decodeEntities(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&", let semicolon = text[index...].firstIndex(of: ";") else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let body = text[text.index(after: index)..<semicolon]
            if let decoded = decode(entityBody: body) {
                result.append(decoded)
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func decode(entityBody body: Substring) -> Character? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            guard let scalarValue = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(scalarValue) else { return nil }
            return Character(scalar)
        }
        if body.hasPrefix("#") {
            guard let scalarValue = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(scalarValue) else { return nil }
            return Character(scalar)
        }
        guard let replacement = namedEntities[String(body)] else { return nil }
        return replacement.count == 1 ? replacement.first : nil
    }
}
