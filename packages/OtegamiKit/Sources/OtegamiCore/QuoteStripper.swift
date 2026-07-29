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
        /// Which marker pattern the split was made at (e.g. `"onWrote"`,
        /// `"blockquote"`, `"quoteBlockLine"`; see the `name` half of
        /// `plainTextQuoteMarkerPatterns`/`htmlQuoteMarkerPatterns` and
        /// `replyOnlyPlainTextQuoteMarkerPatterns`), or `nil` when no marker
        /// was found (or the fallback discarded a too-short split). Task
        /// #90: exposed so `MessageView.sourceTextForSummary()` can log
        /// which case a real message hit — a real-device "still summarizing
        /// the quote" report is otherwise impossible to diagnose from
        /// Console alone.
        public let detectedMarker: String?
    }

    /// A quote marker match: where it starts, and which named pattern
    /// found it (see `SeparatedText.detectedMarker`).
    private struct MarkerMatch {
        let location: Int
        let name: String
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
            return SeparatedText(newText: HTMLTextExtractor.plainText(fromHTML: html), quotedText: "", detectedMarker: nil)
        }
        let newPlainText = HTMLTextExtractor.plainText(fromHTML: split.new)
        guard newPlainText.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumStrippedLength else {
            return SeparatedText(newText: HTMLTextExtractor.plainText(fromHTML: html), quotedText: "", detectedMarker: nil)
        }
        let quotedPlainText = HTMLTextExtractor.plainText(fromHTML: split.quoted)
        return SeparatedText(
            newText: newPlainText,
            quotedText: quotedPlainText.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedMarker: split.markerName
        )
    }

    /// Task #133 (実機報告「引用折りたたみがHTMLメールで効かない」— #123の
    /// 折りたたみはプレーンテキスト表示限定だったが、実際のGmailはほぼ全部
    /// HTML付きでHTML表示が優先されるため実機で機能しなかった): `MessageView`
    /// のHTML表示分岐が使う、**生HTMLのまま**の new/quoted 分割。
    /// `separatingQuotedText(fromHTML:)`は両側を`HTMLTextExtractor`で平文化
    /// してしまう (要約向けの既存契約 — この型のdoc comment参照) — HTML
    /// メールでは新規部分をレイアウトを保ったまま`WKWebView`に渡したいので、
    /// タグ付きのまま返す専用API。`separatingQuotedText(fromHTML:)`と同じ
    /// `splitHTML`/`minimumStrippedLength`の閾値判定を再利用し、分割が
    /// 見つからない(またはフォールバックが発動した)場合は`nil`を返す —
    /// 呼び出し側はその場合、元のHTML全体をそのまま表示する契約
    /// (`MessageView.htmlQuoteHistorySplit`のdoc comment参照)。
    public struct SeparatedHTML: Sendable, Equatable {
        /// 新規部分のHTML (タグ付き、未加工) — `WKWebView`にはこちらだけを渡す。
        public let newHTML: String
        /// 引用履歴部分のHTML (タグ付き、未加工) — `QuoteHistoryParser`へ渡す前に
        /// `HTMLTextExtractor.plainText(fromHTML:)`で平文化する必要がある。
        public let quotedHTML: String
        /// `SeparatedText.detectedMarker`と同じ意味。
        public let detectedMarker: String?
    }

    /// `separatingQuotedText(fromHTML:)`と同じ判定(閾値含む)で分割するが、
    /// 平文化せず生HTMLのまま`newHTML`/`quotedHTML`を返す。分割できない
    /// (マーカーが見つからない、または新規部分が短すぎてフォールバックが
    /// 発動する)場合は`nil`。
    public static func separatingQuotedHTML(fromHTML html: String) -> SeparatedHTML? {
        guard let split = splitHTML(html) else { return nil }
        let newPlainText = HTMLTextExtractor.plainText(fromHTML: split.new)
        guard newPlainText.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumStrippedLength else {
            return nil
        }
        return SeparatedHTML(newHTML: split.new, quotedHTML: split.quoted, detectedMarker: split.markerName)
    }

    /// Finds the earliest known quote-wrapper marker in `html` and splits
    /// `html` right before it into `(new, quoted)`. `nil` when no marker is
    /// found (nothing to split). Truncating mid-document can leave
    /// unbalanced tags behind on either side, which is fine — the only
    /// consumer is `HTMLTextExtractor`'s regex-based stripper, which
    /// doesn't require well-formed HTML.
    private static func splitHTML(_ html: String) -> (new: String, quoted: String, markerName: String)? {
        guard let marker = earliestHTMLQuoteMarkerLocation(in: html),
              let range = Range(NSRange(location: 0, length: marker.location), in: html) else {
            return nil
        }
        return (String(html[range]), String(html[range.upperBound...]), marker.name)
    }

    private static func earliestHTMLQuoteMarkerLocation(in html: String) -> MarkerMatch? {
        let nsHTML = html as NSString
        var earliest: MarkerMatch?

        for (name, pattern) in htmlQuoteMarkerPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)) else { continue }
            let location = match.range.location
            if earliest == nil || location < earliest!.location {
                earliest = MarkerMatch(location: location, name: name)
            }
        }

        return earliest
    }

    private static let htmlQuoteMarkerPatterns: [(name: String, pattern: String)] = [
        // Apple Mail / Thunderbird / generic mail clients: the quoted
        // history is wrapped in (or starts with) a blockquote.
        ("blockquote", #"<blockquote\b"#),
        // Gmail: `<div class="gmail_quote">` wraps the "On ... wrote:"
        // line (`gmail_attr`) plus the quoted blockquote.
        ("gmailQuote", #"<div[^>]*class="[^"]*gmail_quote[^"]*""#),
        // Thunderbird: `<div class="moz-cite-prefix">On ... wrote:</div>`
        // precedes its `<blockquote>` — caught here in case the prefix div
        // sits before the blockquote match above.
        ("mozCitePrefix", #"<div[^>]*class="[^"]*moz-cite-prefix[^"]*""#),
        // Outlook (web/desktop compose-as-HTML): the reply/forward header
        // block and quoted body live inside one of these container ids.
        ("outlookContainer", #"<div[^>]*\bid="(?:divRplyFwdMsg|appendonsend)""#),
        // Outlook-style plain header block pasted into HTML mail: a
        // horizontal rule immediately followed by "From:"/"差出人:".
        ("hrFromBlock", #"<hr\b[^>]*>(?:(?!<hr\b).)*?(?:From|差出人)\s*[:：]"#),
        // Yahoo Mail (webmail HTML export): quoted history is wrapped in
        // `<div class="yahoo_quoted">` (Task #62 gap fix).
        ("yahooQuoted", #"<div[^>]*class="[^"]*yahoo_quoted[^"]*""#),
        // ProtonMail (webmail HTML export): quoted history is wrapped in
        // `<div class="protonmail_quote">` (Task #62 gap fix).
        ("protonmailQuoted", #"<div[^>]*class="[^"]*protonmail_quote[^"]*""#),
        // Generic "indent/rule quote, no named class" wrapper: many
        // webmail exports (and clients not covered by a named-class
        // pattern above) mark quoted history purely with an inline
        // `border-left` on a `<div>` — the same visual convention
        // `gmail_quote`'s own `<blockquote>` uses (`border-left:1px #ccc
        // solid`), just without the class name to key off of (Task #90
        // gap fix: "引用は考慮するものの基本は引用じゃない部分を要約する
        // ようにして欲しい" — a message whose quote wrapper only this
        // style-based cue marks was falling through to "no marker found",
        // so its quote got treated as new text).
        ("borderLeftQuoteDiv", #"<div[^>]*\bstyle="[^"]*border-left\s*:[^"]*"[^>]*>"#),
        // Outlook mobile (iOS/Android) / "new Outlook" web: the reply
        // header block is preceded by a `<div style="border-top:...">`
        // divider instead of an `<hr>` tag or the desktop `divRplyFwdMsg`
        // container id (Task #90 gap fix — mirrors `hrFromBlock` above,
        // div-based instead of hr-based).
        ("borderTopFromBlock", #"<div[^>]*\bstyle="[^"]*border-top\s*:[^"]*"[^>]*>.{0,500}?(?:From|差出人|Sent|送信)\s*[:：]"#),
    ]

    // MARK: - Plain text

    /// Strips known quote markers from plain-text `text` (leading `> `
    /// quote blocks, "On ... wrote:", "----- Original Message -----",
    /// Japanese "〜さんは書きました"/"〜のメール"/"差出人:" header blocks,
    /// ...) and returns everything before the earliest one. Falls back to
    /// the full `text` when stripping would leave too little behind. A thin
    /// wrapper over `separatingQuotedText(fromPlainText:)` (see that
    /// method's doc comment).
    public static func strippingQuotedText(fromPlainText text: String, isReply: Bool = false) -> String {
        separatingQuotedText(fromPlainText: text, isReply: isReply).newText
    }

    /// Same split as `strippingQuotedText(fromPlainText:)`, but also
    /// returns the quoted portion instead of discarding it.
    ///
    /// - Parameter isReply: Task #90: pass `true` when the source message
    ///   carries reply/forward headers (`In-Reply-To`/`References`) — this
    ///   enables `replyOnlyPlainTextQuoteMarkerPatterns`, a small set of
    ///   looser header patterns (a bare "From: Name <addr>" line, an "On
    ///   ... <addr>" line missing its "wrote:" verb because the HTML→plain
    ///   conversion dropped it, ...) that are too prone to false-positive
    ///   on ordinary prose to trust unconditionally (a trip itinerary's
    ///   "From: Tokyo" line, a forwarded press release's dateline, ...) but
    ///   are safe once the headers already confirm this mail *is* a reply.
    ///   Defaults to `false` (unchanged behavior) since most callers/tests
    ///   don't have header info handy.
    public static func separatingQuotedText(fromPlainText text: String, isReply: Bool = false) -> SeparatedText {
        guard let marker = earliestPlainTextQuoteMarkerLocation(in: text, isReply: isReply),
              let range = Range(NSRange(location: 0, length: marker.location), in: text) else {
            return SeparatedText(newText: text, quotedText: "", detectedMarker: nil)
        }

        let newText = String(text[range])
        guard newText.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumStrippedLength else {
            return SeparatedText(newText: text, quotedText: "", detectedMarker: nil)
        }

        let quotedText = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return SeparatedText(newText: newText, quotedText: quotedText, detectedMarker: marker.name)
    }

    private static func earliestPlainTextQuoteMarkerLocation(in text: String, isReply: Bool) -> MarkerMatch? {
        let nsText = text as NSString
        var earliest: MarkerMatch?

        var patterns = plainTextQuoteMarkerPatterns
        if isReply {
            patterns += replyOnlyPlainTextQuoteMarkerPatterns
        }

        for (name, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else { continue }
            let location = match.range.location
            if earliest == nil || location < earliest!.location {
                earliest = MarkerMatch(location: location, name: name)
            }
        }

        if let quoteBlockStart = firstQuoteBlockLineStart(in: text) {
            if earliest == nil || quoteBlockStart < earliest!.location {
                earliest = MarkerMatch(location: quoteBlockStart, name: "quoteBlockLine")
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

    /// Not `private` (unlike `htmlQuoteMarkerPatterns` above): Task #123's
    /// `QuoteHistoryParser` reuses these same attribution-line patterns to
    /// detect where one quoted message ends and the next (older, more
    /// deeply nested) one begins inside an already-split `quotedText` block
    /// — see that type's doc comment for why sharing the detection patterns
    /// (rather than hand-rolling a second, subtly-different set) matters.
    static let plainTextQuoteMarkerPatterns: [(name: String, pattern: String)] = [
        // Gmail/Apple Mail-style English: "On Mon, Jul 27, 2026 at 10:00
        // AM Jane Doe <jane@example.com> wrote:" — the date/name/address
        // portion varies a lot, so this only anchors on the stable
        // "On " ... "wrote:" bookends within one line.
        ("onWrote", #"(?m)^On .{0,300}wrote:\s*$"#),
        // Classic "----- Original Message -----" / "-----原始信件-----"
        // style separators several clients still emit.
        ("originalMessageSeparator", #"(?m)^-{2,}\s*Original Message\s*-{2,}\s*$"#),
        // Japanese Gmail-style: "2026年7月28日(火) 10:00 山田太郎
        // <yamada@example.com>さんは書きました:" (name/address optional,
        // sometimes wrapped so the trailing "さんは書きました" lands on its
        // own line).
        ("japaneseSaidWrote", #"(?m)^\d{4}年\d{1,2}月\d{1,2}日.*さんは(?:こう)?書きました[:：]?\s*$"#),
        // Same Gmail-style Japanese date line when it ends on the address
        // itself rather than "さんは書きました" (the line wraps and the verb
        // lands on the next line, which the pattern above won't anchor).
        ("japaneseSaidWroteAddressEnd", #"(?m)^\d{4}年\d{1,2}月\d{1,2}日.*<[^<>]+>\s*[:：]\s*$"#),
        // Apple Mail (iOS/macOS) Japanese reply header: "2026/07/28 10:00、
        // 山田太郎のメール:" — a different phrasing from Gmail's
        // "さんは書きました" above, not covered by it (Task #62 gap fix).
        ("appleMailJapaneseNoMail", #"(?m)^\d{4}/\d{1,2}/\d{1,2}\s+\d{1,2}:\d{2}.*のメール[:：]?\s*$"#),
        // Outlook-style Japanese forward/reply header block.
        ("japaneseFromHeader", #"(?m)^差出人\s*[:：].*$"#),
        // Outlook-style English forward/reply header block (English UI,
        // or an English mail forwarded from an English client).
        ("outlookEnglishHeaderBlock", #"(?ms)^From:.*?\n(?:Sent|Date):.*?\n(?:To):.*?\n(?:Subject):"#),
    ]

    /// Task #90: a real-device report ("まだ、要約において過去の引用のみが
    /// 要約されてたりする") traced back to replies whose quote header,
    /// after HTML→plain-text flattening, no longer matches any of the
    /// patterns above (a line-wrap dropped "wrote:", or the client used a
    /// bare "From:" line instead of the full Outlook block). These
    /// patterns catch those looser shapes, but each one is common enough
    /// in *ordinary* prose (an itinerary's "From: Tokyo", a forwarded
    /// press release's dateline, ...) that applying them unconditionally
    /// would start truncating messages that were never replies at all.
    /// `earliestPlainTextQuoteMarkerLocation` only consults this list when
    /// the caller already knows (from the message's own In-Reply-To/
    /// References headers) that the mail *is* a reply — seeing a plain
    /// prose sentence that happens to start with "From:" in a message
    /// that isn't a reply is exactly the false-positive case being guarded
    /// against.
    /// Not `private` — see `plainTextQuoteMarkerPatterns`'s doc comment
    /// above; `QuoteHistoryParser` includes these too (unconditionally, not
    /// gated on an `isReply` flag) since by construction every line it
    /// scans already lives inside a confirmed quoted-history block, so the
    /// false-positive risk these patterns exist to guard against in
    /// `QuoteStripper`'s own top-level split doesn't apply.
    static let replyOnlyPlainTextQuoteMarkerPatterns: [(name: String, pattern: String)] = [
        // "On Mon, Jul 27, 2026 at 10:00 AM John Doe <john@example.com>"
        // with no trailing "wrote:" — the verb landed on the next
        // (wrapped) line, or the flattening step dropped it, but the
        // "On ... <address>" bookend is still a strong reply-header cue
        // once we already know this message is a reply.
        ("onWroteAddressOnly", #"(?m)^On .{0,300}<[^<>]+>\s*$"#),
        // A bare "From: Name <address>" line with no Sent/To/Subject
        // block following it — some clients (and lossy HTML→plain
        // conversions of the full Outlook block) leave only this one
        // line behind.
        ("englishFromLineOnly", #"(?m)^From\s*[:：]\s*.+<[^<>]+>\s*$"#),
        // "送信者:" — an alternate Japanese label for "From:" used by some
        // webmail/carrier mail clients, the same single-line shape as
        // "差出人:" above.
        ("japaneseSenderLineOnly", #"(?m)^送信者\s*[:：].*$"#),
    ]
}
