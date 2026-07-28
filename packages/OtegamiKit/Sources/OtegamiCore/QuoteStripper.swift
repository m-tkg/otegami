import Foundation

/// Splits a mail body into "new text" and "quoted history" so AI
/// summarization can treat a long reply chain's accumulated back-and-forth
/// as context rather than the thing being summarized (user report, Task
/// #46: "返信がたくさん繰り返されて過去の文章がたくさんある時、そこは要約の
/// 対象外にして欲しい"; refined in Task #62 after a follow-up report that
/// quoted content still leaked into the summary text itself: "まだ過去の
/// 返信などの引用の内容を要約してるっぽい。完全には無視しなくていいけど、
/// そういう流れがある上で、どういうメールなのかを要約するようにして欲しい"
/// — i.e. don't discard the quote outright, use it as background for what
/// *this* message is saying).
///
/// **Scope: summarize only.** This is deliberately *not* wired into
/// `HTMLTextExtractor`, translation, or body display — a summary is a lossy
/// gist where treating old quoted text as background is exactly what a
/// human skimming the thread would do, but translation/display must show
/// the message as received, quotes included. See
/// `MessageView.sourceTextForSummary()` for the one call site that uses
/// this.
///
/// **Strategy: split at the earliest quote marker, not extract-the-new-
/// part.** Every mail client's quoting convention (Gmail's `gmail_quote`
/// div, Apple Mail/Thunderbird's `<blockquote>`, Outlook's
/// `divRplyFwdMsg`, Yahoo Mail's `yahoo_quoted` div, ProtonMail's
/// `protonmail_quote` div, plain-text `> ` prefixes, "On ... wrote:"
/// headers, "差出人:" header blocks, ...) marks *where the quote begins*,
/// not where it ends — bottom-posted replies exist but top-posting (new
/// text, then the entire quoted history below it) is overwhelmingly the
/// common case this app's own `ComposerView.quotedBody`/
/// `forwardHeaderBlock` also produce. So: find the first recognized
/// marker, split the string there. Pure, deterministic, no ML.
///
/// **Fallback: a forward-only mail, or any case where splitting would
/// leave the new-text side with almost nothing, keeps its full text as
/// `newText` with an empty `quotedText`.** A message that's just "fwd, see
/// below" with no new commentary would otherwise summarize to an empty
/// string; `minimumStrippedLength` guards against that by falling back to
/// the untouched input whenever the new-text side is too short to be a
/// meaningful summary source on its own.
public enum QuoteStripper {
    /// Below this many characters (after trimming whitespace), the
    /// new-text side is assumed to have cut off genuine new content (not
    /// just quoted history) and the original text is used instead.
    static let minimumStrippedLength = 40

    /// The new-text/quoted-history split of a mail body. `quotedText` is
    /// empty whenever there's nothing meaningful to separate out — no
    /// recognized quote marker, or the fallback above kicked in — in which
    /// case `newText` is the full, untouched source.
    public struct SeparatedText: Sendable, Equatable {
        public let newText: String
        public let quotedText: String
    }

    // MARK: - HTML

    /// Strips known quote-wrapper structures from `html`, then flattens the
    /// result through `HTMLTextExtractor` (the same extractor every other
    /// HTML→plain-text path in this app uses) to produce plain text ready
    /// for summarization. Falls back to the *unstripped* HTML's plain text
    /// when stripping would leave too little behind. A thin wrapper over
    /// `separatingQuotedText(fromHTML:)` for callers that only want the
    /// new-text side (kept for the doc-comment/behavior history above;
    /// `MessageView.sourceTextForSummary()` uses the separating form).
    public static func strippingQuotedText(fromHTML html: String) -> String {
        separatingQuotedText(fromHTML: html).newText
    }

    /// Same split as `strippingQuotedText(fromHTML:)`, but also returns the
    /// quoted portion (flattened to plain text the same way) instead of
    /// discarding it.
    public static func separatingQuotedText(fromHTML html: String) -> SeparatedText {
        guard let split = splitHTML(html) else {
            return SeparatedText(newText: HTMLTextExtractor.plainText(fromHTML: html), quotedText: "")
        }
        let newPlainText = HTMLTextExtractor.plainText(fromHTML: split.new)
        guard newPlainText.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumStrippedLength else {
            return SeparatedText(newText: HTMLTextExtractor.plainText(fromHTML: html), quotedText: "")
        }
        let quotedPlainText = HTMLTextExtractor.plainText(fromHTML: split.quoted)
        return SeparatedText(
            newText: newPlainText,
            quotedText: quotedPlainText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Finds the earliest known quote-wrapper marker in `html` and splits
    /// `html` right before it into `(new, quoted)`. `nil` when no marker is
    /// found (nothing to split). Truncating mid-document can leave
    /// unbalanced tags behind on either side, which is fine — the only
    /// consumer is `HTMLTextExtractor`'s regex-based stripper, which
    /// doesn't require well-formed HTML.
    private static func splitHTML(_ html: String) -> (new: String, quoted: String)? {
        guard let location = earliestHTMLQuoteMarkerLocation(in: html),
              let range = Range(NSRange(location: 0, length: location), in: html) else {
            return nil
        }
        return (String(html[range]), String(html[range.upperBound...]))
    }

    private static func earliestHTMLQuoteMarkerLocation(in html: String) -> Int? {
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

        return earliest
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
        // Yahoo Mail (webmail HTML export): quoted history is wrapped in
        // `<div class="yahoo_quoted">` (Task #62 gap fix).
        #"<div[^>]*class="[^"]*yahoo_quoted[^"]*""#,
        // ProtonMail (webmail HTML export): quoted history is wrapped in
        // `<div class="protonmail_quote">` (Task #62 gap fix).
        #"<div[^>]*class="[^"]*protonmail_quote[^"]*""#,
    ]

    // MARK: - Plain text

    /// Strips known quote markers from plain-text `text` (leading `> `
    /// quote blocks, "On ... wrote:", "----- Original Message -----",
    /// Japanese "〜さんは書きました"/"〜のメール"/"差出人:" header blocks,
    /// ...) and returns everything before the earliest one. Falls back to
    /// the full `text` when stripping would leave too little behind. A thin
    /// wrapper over `separatingQuotedText(fromPlainText:)` (see that
    /// method's doc comment).
    public static func strippingQuotedText(fromPlainText text: String) -> String {
        separatingQuotedText(fromPlainText: text).newText
    }

    /// Same split as `strippingQuotedText(fromPlainText:)`, but also
    /// returns the quoted portion instead of discarding it.
    public static func separatingQuotedText(fromPlainText text: String) -> SeparatedText {
        guard let location = earliestPlainTextQuoteMarkerLocation(in: text),
              let range = Range(NSRange(location: 0, length: location), in: text) else {
            return SeparatedText(newText: text, quotedText: "")
        }

        let newText = String(text[range])
        guard newText.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumStrippedLength else {
            return SeparatedText(newText: text, quotedText: "")
        }

        let quotedText = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return SeparatedText(newText: newText, quotedText: quotedText)
    }

    private static func earliestPlainTextQuoteMarkerLocation(in text: String) -> Int? {
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

        return earliest
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
        // Apple Mail (iOS/macOS) Japanese reply header: "2026/07/28 10:00、
        // 山田太郎のメール:" — a different phrasing from Gmail's
        // "さんは書きました" above, not covered by it (Task #62 gap fix).
        #"(?m)^\d{4}/\d{1,2}/\d{1,2}\s+\d{1,2}:\d{2}.*のメール[:：]?\s*$"#,
        // Outlook-style Japanese forward/reply header block.
        #"(?m)^差出人\s*[:：].*$"#,
        // Outlook-style English forward/reply header block (English UI,
        // or an English mail forwarded from an English client).
        #"(?ms)^From:.*?\n(?:Sent|Date):.*?\n(?:To):.*?\n(?:Subject):"#,
    ]
}
