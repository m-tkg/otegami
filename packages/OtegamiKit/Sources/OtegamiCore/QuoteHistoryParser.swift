import Foundation

/// Task #123 (Spark 参考「引用履歴をメッセージ単位に分解して時系列表示」):
/// breaks `QuoteStripper.SeparatedText.quotedText` — the "everything after
/// the first quote marker" blob that stripper produces — down further, into
/// one `Segment` per historical message in the reply chain, so
/// `MessageView`'s quote-history card can render each past message with its
/// own sender/timestamp/body instead of one undifferentiated wall of `>`
/// text.
///
/// **Why nesting depth is the ordering signal.** Top-posting mail clients
/// (this app's own `ComposerView.quotedBody` included) quote the *entire*
/// previous message — attribution line and all — and prefix every one of
/// its lines with one more `>` than that message itself carried. The result
/// is a strictly increasing staircase: the most recently quoted message's
/// attribution sits at the shallowest depth, its own body one level deeper
/// (the body is what got the extra `>` stacked on top of whatever it
/// already had), and the message *it* was replying to starts even deeper
/// still. A message dated 2026-07-28 fixture (see
/// `QuoteHistoryParserTests`) demonstrates this concretely: attribution
/// lines land at depths 1/3/5/7 and their bodies immediately follow one
/// level deeper (2/4/6/8) — each transition, attribution or body, adds
/// exactly one `>`. Walking `quotedText` top-to-bottom and cutting a new
/// `Segment` every time a line (after removing its own leading `>` run)
/// matches a known attribution shape therefore recovers chronological order
/// "for free": segments come out newest-quoted-first, oldest-last, which is
/// also the order this app's own `on-screen` fixtures are already written
/// in top-down.
///
/// **Detection vs. extraction are deliberately separate concerns.**
/// Detecting "is this line an attribution line at all" reuses
/// `QuoteStripper.plainTextQuoteMarkerPatterns`/
/// `replyOnlyPlainTextQuoteMarkerPatterns` verbatim (per Task #123's brief:
/// "帰属行パターン...QuoteStripper の既存パターンを流用/共有") — those
/// patterns are already tuned against real client output and shared here
/// rather than duplicated. Once a line is confirmed to *be* an attribution,
/// *extracting* a display-ready sender name / timestamp out of it is this
/// type's own, additional job (`attributionExtractors`) — `QuoteStripper`
/// never needed to parse that far, it only needed to find where to cut.
///
/// **Fallback is the load-bearing design constraint.** Real mail is messy —
/// a client with an unrecognized attribution phrasing, a forwarded message
/// with no attribution line at all (just raw `> ` blocks), a body that
/// itself contains a line starting with `>` for unrelated reasons — any of
/// these can make segmentation come out wrong or empty. Rather than risk
/// silently mangling (or worse, dropping) a real message body, `parse(_:)`
/// falls back to `.unparsed(quotedText)` — the *original, untouched* string
/// — whenever it can't find at least one confident attribution match. The
/// UI's contract (`MessageView`'s quote-history card) is to render
/// `.unparsed`'s payload as plain text inside the same card rather than
/// attempt the per-segment layout, so a parse miss degrades to "looks like
/// the old undifferentiated blob" rather than "email content missing/wrong".
public enum QuoteHistoryParser {
    /// One historical message recovered from a quoted-history blob.
    public struct Segment: Sendable, Equatable {
        /// The sender's display name, if the attribution line's shape let
        /// one be extracted (e.g. "Sato Hanako" out of "...Sato Hanako
        /// <sato.hanako@example.com>:"). `nil` when the attribution matched
        /// (so a segment boundary still exists) but the name couldn't be
        /// isolated (e.g. a bare "----- Original Message -----" separator).
        public let senderName: String?
        /// The date/time portion of the attribution line, as found — kept
        /// as the original source substring (not reparsed into a `Date`)
        /// since these come from many different, locale-specific formats
        /// and displaying the sender's own original wording is more
        /// trustworthy than a reformat that might mis-parse it. `nil` when
        /// not extractable.
        public let timestamp: String?
        /// The attribution line's full text (leading `>` runs already
        /// stripped), for callers that want to show/log the original
        /// wording rather than (or alongside) `senderName`/`timestamp` —
        /// e.g. when both extracted fields are `nil`.
        public let attributionText: String
        /// This segment's body — the quoted message's own text, with each
        /// line's leading `>` run (and the one extra level contributed by
        /// whatever quoted *this* message) already stripped, "> " artifacts
        /// gone, trimmed of leading/trailing blank lines.
        public let body: String
        /// The attribution line's nesting depth (number of leading `>`
        /// tokens) — exposed mainly for tests asserting the "order recovered
        /// from nesting depth" behavior described in this type's doc
        /// comment; `MessageView` doesn't need to read it (segments already
        /// come out in display order).
        public let depth: Int
    }

    public enum ParseResult: Sendable, Equatable {
        /// At least one confident attribution boundary was found — `Segment`s
        /// are in display order (most recently quoted message first).
        case segments([Segment])
        /// No confident attribution boundary was found anywhere in
        /// `quotedText` — the original, untouched string, for the caller to
        /// show as an unstructured fallback rather than risk a wrong split.
        case unparsed(String)
    }

    /// Segments `quotedText` (the `quotedText` half of
    /// `QuoteStripper.SeparatedText`, i.e. already known to start at the
    /// first quote marker) into per-message `Segment`s. Falls back to
    /// `.unparsed(quotedText)`, verbatim, whenever no attribution line can
    /// be confidently located.
    public static func parse(_ quotedText: String) -> ParseResult {
        let rawLines = quotedText.components(separatedBy: "\n")
        let dequoted = rawLines.map(dequote)

        var segments: [Segment] = []
        var currentAttribution: (depth: Int, text: String)?
        var currentBodyLines: [String] = []
        var index = 0

        func flush() {
            guard let attribution = currentAttribution else { return }
            let extraction = extractSenderAndTimestamp(from: attribution.text)
            let body = currentBodyLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            segments.append(
                Segment(
                    senderName: extraction.name,
                    timestamp: extraction.timestamp,
                    attributionText: attribution.text,
                    body: body,
                    depth: attribution.depth
                )
            )
        }

        while index < dequoted.count {
            if let block = matchOutlookHeaderBlock(dequoted, at: index) {
                flush()
                currentAttribution = (depth: block.depth, text: block.attributionText)
                currentBodyLines = []
                index += block.linesConsumed
                continue
            }

            let (depth, content) = dequoted[index]
            if isAttributionLine(content) {
                flush()
                currentAttribution = (depth: depth, text: content.trimmingCharacters(in: .whitespaces))
                currentBodyLines = []
            } else {
                currentBodyLines.append(content)
            }
            index += 1
        }
        flush()

        guard !segments.isEmpty else {
            return .unparsed(quotedText)
        }
        return .segments(segments)
    }

    // MARK: - Dequoting

    /// Strips a line's leading run of `>` markers (tolerating the common
    /// "no space" `>>>` and "space-separated" `> > >` variants, and any
    /// stray leading whitespace before/between them), returning how many
    /// levels deep it was and the remaining content.
    private static func dequote(_ line: String) -> (depth: Int, content: String) {
        var remaining = Substring(line)
        var depth = 0
        while true {
            let withoutLeadingSpace = remaining.drop(while: { $0 == " " || $0 == "\t" })
            guard withoutLeadingSpace.first == ">" else {
                remaining = withoutLeadingSpace
                break
            }
            depth += 1
            remaining = withoutLeadingSpace.dropFirst()
        }
        return (depth, String(remaining))
    }

    // MARK: - Attribution detection (shared with QuoteStripper)

    /// All single-line attribution shapes `QuoteStripper` already knows how
    /// to recognize, reused verbatim (see this type's doc comment for why).
    /// The `replyOnly` patterns are included unconditionally here — see
    /// their doc comment on `QuoteStripper` for why that's safe in this
    /// context even though `QuoteStripper` itself gates them on `isReply`.
    private static let attributionDetectionPatterns: [(name: String, pattern: String)] =
        QuoteStripper.plainTextQuoteMarkerPatterns + QuoteStripper.replyOnlyPlainTextQuoteMarkerPatterns

    private static func isAttributionLine(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let nsContent = trimmed as NSString
        for (_, pattern) in attributionDetectionPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            if regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: nsContent.length)) != nil {
                return true
            }
        }
        return false
    }

    /// The Outlook-style four-line "From:/Sent:/To:/Subject:" header block
    /// (`QuoteStripper`'s `outlookEnglishHeaderBlock`/`japaneseFromHeader`
    /// pattern's un-collapsed shape) doesn't fit the "one attribution =
    /// one line" model every other pattern above does — it needs to
    /// consume up to 4 lines as a single attribution unit so "Sent:"/"To:"/
    /// "Subject:" don't each get misread as the start of their own
    /// (bodyless) segment. Requires the "From:"/"差出人:" line and at least
    /// a following "Sent:"/"Date:"/"送信日時:" line at the *same* depth to
    /// fire — a bare single "From:" line with no such follow-up still falls
    /// through to `isAttributionLine`'s own `englishFromLineOnly`/
    /// `japaneseFromHeader` single-line match instead.
    private static func matchOutlookHeaderBlock(
        _ dequoted: [(depth: Int, content: String)], at index: Int
    ) -> (depth: Int, attributionText: String, linesConsumed: Int)? {
        guard index < dequoted.count else { return nil }
        let (depth, fromLine) = dequoted[index]
        let trimmedFrom = fromLine.trimmingCharacters(in: .whitespaces)
        guard matches(trimmedFrom, pattern: #"^(?:From|差出人)\s*[:：]"#) else { return nil }

        var consumed = 1
        var blockLines = [trimmedFrom]
        // Optional Sent/Date, To, Subject lines — collected as long as they
        // stay at the same depth and match one of the expected labels.
        // Task #123 doesn't need this to be strict about exact ordering
        // (some clients reorder To/Subject), only that at least a "when"
        // line follows, confirming this really is the multi-line block
        // rather than a coincidental lone "From:" line.
        var sawSentOrDate = false
        var lookahead = index + 1
        while lookahead < dequoted.count, blockLines.count < 4 {
            let (nextDepth, nextContent) = dequoted[lookahead]
            guard nextDepth == depth else { break }
            let trimmedNext = nextContent.trimmingCharacters(in: .whitespaces)
            guard matches(trimmedNext, pattern: #"^(?:Sent|Date|送信日時|To|宛先|Subject|件名)\s*[:：]"#) else { break }
            if matches(trimmedNext, pattern: #"^(?:Sent|Date|送信日時)\s*[:：]"#) {
                sawSentOrDate = true
            }
            blockLines.append(trimmedNext)
            consumed += 1
            lookahead += 1
        }
        guard sawSentOrDate else { return nil }
        return (depth: depth, attributionText: blockLines.joined(separator: "\n"), linesConsumed: consumed)
    }

    // MARK: - Sender/timestamp extraction

    /// Best-effort capture-group regexes for pulling a display name and
    /// timestamp out of an already-confirmed attribution line/block. Tried
    /// in order; the first to match wins. Deliberately separate from
    /// `attributionDetectionPatterns` above — detection only needs to know
    /// a line *is* an attribution, extraction needs to know *which* shape
    /// it is to pull the right substrings out.
    private static let attributionExtractors: [String] = [
        // Japanese Gmail-style, verb form: "2026年7月27日(月) 10:00 山田太郎
        // <yamada@example.com>さんは書きました:"
        #"^(?<date>\d{4}年\d{1,2}月\d{1,2}日(?:\([^)]{1,4}\))?\s*\d{1,2}:\d{2})\s*(?<name>[^<>]*?)\s*(?:<[^<>]+>)?\s*さんは(?:こう)?書きました[:：]?\s*$"#,
        // Japanese Gmail-style, address-end form (Task #123's own example):
        // "2026年5月10日(日) 17:43 名前 <addr>:"
        #"^(?<date>\d{4}年\d{1,2}月\d{1,2}日(?:\([^)]{1,4}\))?\s*\d{1,2}:\d{2})\s*(?<name>[^<>]+?)\s*<[^<>]+>\s*[:：]\s*$"#,
        // Apple Mail (iOS/macOS) Japanese: "2026/07/28 10:00、山田太郎のメール:"
        #"^(?<date>\d{4}/\d{1,2}/\d{1,2}\s+\d{1,2}:\d{2})、\s*(?<name>.+?)のメール[:：]?\s*$"#,
        // English "On <date>, <name> <addr> wrote:" — the date portion
        // itself often contains its own commas ("Mon, Jul 27, 2026 at
        // 10:00 AM, John Doe <...> wrote:"), so `date` is greedy: it grabs
        // as much as it can and backtracks only as far as needed for
        // `name`/`<addr>`/`wrote:` to still match, landing on the *last*
        // comma (the one actually separating the date from the name)
        // rather than the first one it finds.
        #"^On (?<date>.+),\s*(?<name>[^<>]+?)\s*<[^<>]+>\s*wrote:\s*$"#,
        // English "On <date> <name> <addr> wrote:" (no comma separator)
        #"^On (?<date>.+?)\s+(?<name>[^<>,]+?)\s*<[^<>]+>\s*wrote:\s*$"#,
        // English, no trailing "wrote:" (line-wrap dropped it): "On <date>,
        // <name> <addr>" — same greedy-`date` reasoning as above.
        #"^On (?<date>.+),\s*(?<name>[^<>]+?)\s*<[^<>]+>\s*$"#,
        // A bare "From:"/"差出人:"/"送信者:" line (or the first line of the
        // multi-line Outlook block): "From: Name <addr>"
        #"^(?:差出人|送信者|From)\s*[:：]\s*(?<name>[^<>]+?)\s*<[^<>]+>\s*$"#,
    ]

    /// Extracts a `date:`/`Date:`/`送信日時:` line's value out of a
    /// multi-line Outlook-style attribution block (`matchOutlookHeaderBlock`'s
    /// output), and the name/address out of its "From:"/"差出人:" line.
    private static func extractSenderAndTimestamp(from attributionText: String) -> (name: String?, timestamp: String?) {
        if attributionText.contains("\n") {
            var name: String?
            var timestamp: String?
            for line in attributionText.components(separatedBy: "\n") {
                if name == nil, let match = firstCaptureMatch(line, pattern: #"^(?:差出人|From)\s*[:：]\s*(?<name>[^<>]+?)\s*(?:<[^<>]+>)?\s*$"#) {
                    name = match["name"]
                }
                if timestamp == nil, let match = firstCaptureMatch(line, pattern: #"^(?:Sent|Date|送信日時)\s*[:：]\s*(?<date>.+)$"#) {
                    timestamp = match["date"]
                }
            }
            return (name?.trimmingCharacters(in: .whitespaces), timestamp?.trimmingCharacters(in: .whitespaces))
        }

        for pattern in attributionExtractors {
            guard let match = firstCaptureMatch(attributionText, pattern: pattern) else { continue }
            let name = match["name"]?.trimmingCharacters(in: .whitespaces)
            let date = match["date"]?.trimmingCharacters(in: .whitespaces)
            if (name?.isEmpty ?? true) && (date?.isEmpty ?? true) { continue }
            return (name?.isEmpty == false ? name : nil, date?.isEmpty == false ? date : nil)
        }
        return (nil, nil)
    }

    // MARK: - Regex helpers

    private static func matches(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// Runs `pattern` (which must use `(?<name>...)`-style named capture
    /// groups) against `text` and returns each named group's matched
    /// substring, keyed by group name. Groups present in the pattern but
    /// that didn't participate in the match (e.g. an optional group) are
    /// simply absent from the result rather than mapped to an empty string.
    private static func firstCaptureMatch(_ text: String, pattern: String) -> [String: String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var result: [String: String] = [:]
        for name in ["name", "date"] {
            let range = match.range(withName: name)
            guard range.location != NSNotFound else { continue }
            result[name] = ns.substring(with: range)
        }
        return result
    }
}
