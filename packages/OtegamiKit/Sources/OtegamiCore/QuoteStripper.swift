import Foundation

/// Cuts the quoted-history tail off a mail body so AI summarization only
/// sees the sender's new text, not the whole back-and-forth a long reply
/// chain has accumulated (user report, Task #46: "返信がたくさん繰り返され
/// て過去の文章がたくさんある時、そこは要約の対象外にして欲しい").
///
/// **Scope: summarize only.** This is deliberately *not* wired into
/// `HTMLTextExtractor`, translation, or body display — a summary is a lossy
/// gist where dropping old quoted text is exactly what a human skimming the
/// thread would do, but translation/display must show the message as
/// received, quotes included. See `MessageView.sourceTextForSummary()` for
/// the one call site that uses this.
///
/// **Strategy: truncate at the earliest quote marker, not extract-the-new-
/// part.** Every mail client's quoting convention (Gmail's `gmail_quote`
/// div, Apple Mail/Thunderbird's `<blockquote>`, Outlook's
/// `divRplyFwdMsg`, plain-text `> ` prefixes, "On ... wrote:" headers, "差出
/// 人:" header blocks, ...) marks *where the quote begins*, not where it
/// ends — bottom-posted replies exist but top-posting (new text, then the
/// entire quoted history below it) is overwhelmingly the common case this
/// app's own `ComposerView.quotedBody`/`forwardHeaderBlock` also produce.
/// So: find the first recognized marker, drop everything from there to the
/// end of the string. Pure, deterministic, no ML.
///
/// **Fallback: a forward-only mail, or any case where stripping ate nearly
/// everything, keeps its full text.** A message that's just "fwd, see
/// below" with no new commentary would otherwise summarize to an empty
/// string; `minimumStrippedLength` guards against that by falling back to
/// the untouched input whenever the stripped result is too short to be a
/// meaningful summary source on its own.
public enum QuoteStripper {
    /// Below this many characters (after trimming whitespace), the
    /// stripped result is assumed to have removed genuine new content
    /// (not just quoted history) and the original text is used instead.
    static let minimumStrippedLength = 40

    // MARK: - HTML

    /// Strips known quote-wrapper structures from `html`, then flattens the
    /// result through `HTMLTextExtractor` (the same extractor every other
    /// HTML→plain-text path in this app uses) to produce plain text ready
    /// for summarization. Falls back to the *unstripped* HTML's plain text
    /// when stripping would leave too little behind.
    public static func strippingQuotedText(fromHTML html: String) -> String {
        let stripped = HTMLTextExtractor.plainText(fromHTML: truncatedHTML(html))
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumStrippedLength {
            return stripped
        }
        return HTMLTextExtractor.plainText(fromHTML: html)
    }

    /// Finds the earliest known quote-wrapper marker in `html` (Gmail's
    /// `gmail_quote`/`gmail_attr` divs, Apple Mail/Thunderbird
    /// `<blockquote>`, Thunderbird's `moz-cite-prefix` div, Outlook's
    /// `divRplyFwdMsg`/`appendonsend` ids, or an `<hr>` immediately
    /// followed by a From:/差出人: header block) and truncates `html` right
    /// before it. No match: `html` unchanged. Truncating mid-document can
    /// leave unbalanced tags behind, which is fine — the only consumer is
    /// `HTMLTextExtractor`'s regex-based stripper, which doesn't require
    /// well-formed HTML.
    private static func truncatedHTML(_ html: String) -> String {
        let nsHTML = html as NSString
        var earliest: Int?

        for pattern in htmlQuoteMarkerPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)) else { continue }
            let location = match.range.location
            if earliest == nil || location < earliest! {
                earliest = location
            }
        }

        guard let earliest, let range = Range(NSRange(location: 0, length: earliest), in: html) else { return html }
        return String(html[range])
    }

    private static let htmlQuoteMarkerPatterns: [String] = [
        // Apple Mail / Thunderbird / generic mail clients: the quoted
        // history is wrapped in (or starts with) a blockquote.
        #"<blockquote\b"#,
        // Gmail: `<div class="gmail_quote">` wraps the "On ... wrote:"
        // line (`gmail_attr`) plus the quoted blockquote.
        #"<div[^>]*class="[^"]*gmail_quote[^"]*""#,
        // Thunderbird: `<div class="moz-cite-prefix">On ... wrote:</div>`
        // precedes its `<blockquote>` — caught here in case the prefix div
        // sits before the blockquote match above.
        #"<div[^>]*class="[^"]*moz-cite-prefix[^"]*""#,
        // Outlook (web/desktop compose-as-HTML): the reply/forward header
        // block and quoted body live inside one of these container ids.
        #"<div[^>]*\bid="(?:divRplyFwdMsg|appendonsend)""#,
        // Outlook-style plain header block pasted into HTML mail: a
        // horizontal rule immediately followed by "From:"/"差出人:".
        #"<hr\b[^>]*>(?:(?!<hr\b).)*?(?:From|差出人)\s*[:：]"#,
    ]

    // MARK: - Plain text

    /// Strips known quote markers from plain-text `text` (leading `> `
    /// quote blocks, "On ... wrote:", "----- Original Message -----",
    /// Japanese "〜さんは書きました"/"差出人:" header blocks, ...) and
    /// returns everything before the earliest one. Falls back to the full
    /// `text` when stripping would leave too little behind.
    public static func strippingQuotedText(fromPlainText text: String) -> String {
        let stripped = truncatedPlainText(text)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= minimumStrippedLength ? stripped : text
    }

    private static func truncatedPlainText(_ text: String) -> String {
        let nsText = text as NSString
        var earliest: Int?

        for pattern in plainTextQuoteMarkerPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else { continue }
            let location = match.range.location
            if earliest == nil || location < earliest! {
                earliest = location
            }
        }

        if let quoteBlockStart = firstQuoteBlockLineStart(in: text) {
            if earliest == nil || quoteBlockStart < earliest! {
                earliest = quoteBlockStart
            }
        }

        guard let earliest, let range = Range(NSRange(location: 0, length: earliest), in: text) else { return text }
        return String(text[range])
    }

    /// The UTF-16 offset of the first line whose trimmed content starts
    /// with `>` (a plain-text quoted block, the convention this app's own
    /// `ComposerView.quotedBody` also produces on reply). `nil` if no line
    /// looks like a quote marker.
    private static func firstQuoteBlockLineStart(in text: String) -> Int? {
        let nsText = text as NSString
        var searchStart = 0
        while searchStart <= nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: searchStart, length: 0))
            guard lineRange.length > 0 else { break }
            let line = nsText.substring(with: lineRange)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(">") {
                return lineRange.location
            }
            let nextStart = lineRange.location + lineRange.length
            guard nextStart > searchStart else { break }
            searchStart = nextStart
        }
        return nil
    }

    private static let plainTextQuoteMarkerPatterns: [String] = [
        // Gmail/Apple Mail-style English: "On Mon, Jul 27, 2026 at 10:00
        // AM Jane Doe <jane@example.com> wrote:" — the date/name/address
        // portion varies a lot, so this only anchors on the stable
        // "On " ... "wrote:" bookends within one line.
        #"(?m)^On .{0,300}wrote:\s*$"#,
        // Classic "----- Original Message -----" / "-----原始信件-----"
        // style separators several clients still emit.
        #"(?m)^-{2,}\s*Original Message\s*-{2,}\s*$"#,
        // Japanese Gmail-style: "2026年7月28日(火) 10:00 山田太郎
        // <yamada@example.com>さんは書きました:" (name/address optional,
        // sometimes wrapped so the trailing "さんは書きました" lands on its
        // own line).
        #"(?m)^\d{4}年\d{1,2}月\d{1,2}日.*さんは(?:こう)?書きました[:：]?\s*$"#,
        // Same Gmail-style Japanese date line when it ends on the address
        // itself rather than "さんは書きました" (the line wraps and the verb
        // lands on the next line, which the pattern above won't anchor).
        #"(?m)^\d{4}年\d{1,2}月\d{1,2}日.*<[^<>]+>\s*[:：]\s*$"#,
        // Outlook-style Japanese forward/reply header block.
        #"(?m)^差出人\s*[:：].*$"#,
        // Outlook-style English forward/reply header block (English UI,
        // or an English mail forwarded from an English client).
        #"(?ms)^From:.*?\n(?:Sent|Date):.*?\n(?:To):.*?\n(?:Subject):"#,
    ]
}
