import Foundation

/// A small, dependency-free HTML→plain-text extractor. Used by
/// `SyncEngine.BodyFetcher` (M2) to derive `messageBody.plainText` for
/// messages whose server-side MIME structure has an HTML part but no
/// `text/plain` alternative — a hand-rolled, single-pass linear scanner
/// rather than a real parser (deliberately: this only ever needs to
/// produce a *readable fallback* for search/snippet/plain-text display,
/// not a faithful rendering, so a full HTML parser would be more
/// machinery than the job needs) and pure Swift so it stays usable from
/// `OtegamiCore` (Linux-compatible, no `WebKit`/`NSAttributedString`).
///
/// **Security note (Task #168 / SEC-C, `CLAUDE-SECURITY` F11 and F6):**
/// this used to be built from a chain of `NSRegularExpression` passes
/// (`<(script|style)\b[^>]*>.*?</\1>` and `<[^>]+>` for tag stripping,
/// plus an unbounded `firstIndex(of: ";")` rescan per `&` for entity
/// decoding). Both were worst-case *quadratic* in the input length: an
/// attacker-controlled HTML mail body — no interaction required, just
/// being received and prefetched/rendered — could hang the sync actor
/// and the main thread for minutes to hours. `stripTagsAndBlocks` and
/// `decodeEntities` below are hand-written **linear**-time scanners
/// instead: every scan is bounded (a tag-terminator search stops at the
/// very next `<` as well as `>`, so a single unterminated tag can never
/// trigger a rescan of the remaining document; an entity lookahead is
/// capped at `maxEntityLength`, since real HTML entities are only ever a
/// handful of characters). `maxInputLength` additionally caps the total
/// work regardless of algorithmic complexity, since this function only
/// ever needs to produce a bounded-size fallback, never a faithful
/// rendering of an arbitrarily large document.
public enum HTMLTextExtractor {
    /// This function only produces a search/snippet/plain-text fallback,
    /// never anything shown as the primary rendering — truncating a
    /// pathologically large HTML part costs nothing functionally, and
    /// bounds total work independent of the (now-linear, but still
    /// unbounded-input) scanners below. A few hundred KB is far more than
    /// any legitimate email body needs for a readable fallback.
    private static let maxInputLength = 512_000

    private static let blockClosingTags: Set<String> = [
        "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote",
    ]

    /// Strips tags/scripts/styles from `html`, turns block-level
    /// boundaries into newlines, and decodes the handful of HTML entities
    /// that show up in the wild. Not a full HTML5 entity table — good
    /// enough for the common named entities plus numeric/hex references.
    public static func plainText(fromHTML html: String) -> String {
        let capped = html.count > maxInputLength ? String(html.prefix(maxInputLength)) : html

        var text = stripTagsAndBlocks(capped)
        text = decodeEntities(text)

        // Collapse runs of blank lines left behind by the block-boundary
        // substitutions above, and trim. `\n{3,}` is a single literal
        // character class with no adjacent overlapping quantifiers, so
        // it isn't subject to the backtracking blowup the tag/entity
        // scanners above were rewritten to avoid.
        text = replacing(pattern: "\\n{3,}", in: text, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    // MARK: - Tag stripping

    /// A single linear pass that drops `<script>`/`<style>` elements
    /// (including their content), turns `<br>` and block-level closing
    /// tags into newlines, and strips every other tag — replacing what
    /// used to be three chained backtracking regex passes over the whole
    /// text.
    ///
    /// Every inner scan for a tag's terminating `>` stops early at the
    /// next `<` too (real HTML never nests a `<` inside a tag). This is
    /// what keeps the whole function linear: without it, an unterminated
    /// tag (e.g. a mail body that's just `<script` repeated with no `>`
    /// anywhere) would make each failed attempt scan all the way to the
    /// next real `>` — or to the end of the document if there isn't
    /// one — and that failure would be retried from the next `<`,
    /// recreating the same O(n²) behavior the regex chain had. Stopping
    /// at the nearer of `<`/`>` bounds each attempt by the gap to the
    /// next `<`, and those gaps are disjoint, so total work stays O(n).
    private static func stripTagsAndBlocks(_ html: String) -> String {
        let chars = Array(html)
        let n = chars.count
        var result = ""
        result.reserveCapacity(n)
        var i = 0

        while i < n {
            guard chars[i] == "<" else {
                result.append(chars[i])
                i += 1
                continue
            }

            var k = i + 1
            while k < n, chars[k] != "<", chars[k] != ">" {
                k += 1
            }
            guard k < n, chars[k] == ">" else {
                // No terminator before the next '<' (or end of input) —
                // not a well-formed tag, just a literal '<'.
                result.append("<")
                i += 1
                continue
            }

            var j = i + 1
            var isClosing = false
            if j < k, chars[j] == "/" {
                isClosing = true
                j += 1
            }
            let nameStart = j
            while j < k, chars[j].isLetter {
                j += 1
            }
            let name = (j > nameStart) ? String(chars[nameStart..<j]).lowercased() : ""
            let isSelfClosing = k > i + 1 && chars[k - 1] == "/"

            if !isClosing, !isSelfClosing, name == "script" || name == "style" {
                let contentStart = k + 1
                if let closeEnd = findClosingTagEnd(name: name, in: chars, from: contentStart) {
                    i = closeEnd
                } else {
                    // No matching closing tag anywhere in the
                    // (already length-capped) remainder — drop the
                    // rest rather than leak raw script/style text.
                    i = n
                }
                continue
            }

            if isClosing, blockClosingTags.contains(name) {
                result.append("\n")
            } else if !isClosing, name == "br" {
                result.append("\n")
            }
            i = k + 1
        }
        return result
    }

    /// Scans forward from `start` for a case-insensitive `</name>`,
    /// returning the index just past its `>`, or `nil` if none exists in
    /// the rest of the (already length-capped) text. A single bounded
    /// linear scan — no regex, no backtracking: every rejected `<` costs
    /// at most `name.count` comparisons before moving on by one
    /// character, so total work is O(n) regardless of how many
    /// near-miss `<...` sequences the attacker packs in.
    private static func findClosingTagEnd(name: String, in chars: [Character], from start: Int) -> Int? {
        let n = chars.count
        let lowerName = Array(name)
        var i = start
        while i < n {
            guard chars[i] == "<" else {
                i += 1
                continue
            }
            var j = i + 1
            guard j < n, chars[j] == "/" else {
                i += 1
                continue
            }
            j += 1
            var matched = true
            for expected in lowerName {
                guard j < n, chars[j].lowercased().first == expected else {
                    matched = false
                    break
                }
                j += 1
            }
            if matched {
                while j < n, chars[j] != ">" {
                    j += 1
                }
                guard j < n else { return nil }
                return j + 1
            }
            i += 1
        }
        return nil
    }

    // MARK: - Entity decoding

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
    ]

    /// The longest real HTML entity body (named or numeric) is a
    /// handful of characters — bounding the lookahead here means a run
    /// of `&` with no nearby `;` (or one `;` at the very end of a huge
    /// input) can no longer make this function's cost quadratic: without
    /// this bound, every `&` searched the *entire rest of the string*
    /// for a `;` and, if found, copied that entire span into a `String`
    /// for the dictionary lookup.
    private static let maxEntityLength = 32

    private static func decodeEntities(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&" else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let bodyStart = text.index(after: index)
            let searchLimit = text.index(bodyStart, offsetBy: maxEntityLength, limitedBy: text.endIndex) ?? text.endIndex
            if let semicolon = text[bodyStart..<searchLimit].firstIndex(of: ";"),
               let decoded = decode(entityBody: text[bodyStart..<semicolon]) {
                result.append(decoded)
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = bodyStart
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
