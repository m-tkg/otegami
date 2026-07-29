import Foundation

/// Task #129 (作成画面リッチテキスト化): a neutral, `NSAttributedString`-free
/// model of formatted body text — the "AttributedString" side of the
/// AttributedString⇄HTML serialization the task calls for, kept as its own
/// pure-Swift type (rather than working with `NSAttributedString`/`UIFont`
/// directly) so it stays usable from `OtegamiCore` (Linux-compatible, no
/// UIKit/AppKit — same reasoning as `HTMLTextExtractor`'s doc comment) and
/// is trivially unit-testable without a UIKit/SwiftUI host.
///
/// `apps/Otegami/Sources/Features/Composer/RichTextAttributedString.swift`
/// is the one place that converts between this type and the real
/// `NSAttributedString` the UITextView-backed composer editor actually
/// edits — this type itself never touches `NSAttributedString`.
///
/// Structure mirrors what the formatting bar exposes: paragraphs (split on
/// `"\n"`) each optionally tagged as a list item (bulleted/numbered) at some
/// indent level, containing runs of text with independent bold/italic/
/// underline/strikethrough flags. No font/color/size — Task #129's second
/// stage (フォント選択/文字色/背景色/リンク/引用ブロック) extends this if it lands;
/// this stage intentionally keeps the model to exactly the first-stage
/// formatting set.
public struct RichTextRun: Equatable, Sendable, Codable {
    public var text: String
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderline: Bool
    public var isStrikethrough: Bool

    public init(
        text: String,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderline: Bool = false,
        isStrikethrough: Bool = false
    ) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.isStrikethrough = isStrikethrough
    }

    /// Whether this run carries no formatting at all — used by the HTML
    /// encoder to skip wrapping plain runs in any inline tag, and by the
    /// plain-text deriver (nothing to strip either way).
    var isPlain: Bool { !isBold && !isItalic && !isUnderline && !isStrikethrough }
}

/// A paragraph's list membership — `none` for an ordinary paragraph,
/// `bullet`/`ordered` for one line of a `<ul>`/`<ol>`. Numbering itself
/// (`1.`, `2.`, ...) is never stored per-paragraph — it's derived positionally
/// from how many consecutive `.ordered` paragraphs (at the same indent level)
/// precede this one, the same way real `<ol>` markup numbers itself; storing
/// an explicit index would let it drift out of sync with insertions/deletions.
public enum RichTextListStyle: Equatable, Sendable, Codable {
    case none
    case bullet
    case ordered
}

public struct RichTextParagraph: Equatable, Sendable, Codable {
    public var runs: [RichTextRun]
    public var listStyle: RichTextListStyle
    /// 0 = no extra indent (plan: "インデント増減"). Purely presentational
    /// for a non-list paragraph (renders as nested `<blockquote>` — the
    /// same tag mail clients already use for quote indentation, so a
    /// received message's quoted reply keeps reading the same way through
    /// a client that doesn't understand this app's specific markup); for a
    /// list paragraph it nests the `<ul>`/`<ol>` one level deeper per unit,
    /// matching how nested lists are conventionally authored.
    public var indentLevel: Int

    public init(runs: [RichTextRun], listStyle: RichTextListStyle = .none, indentLevel: Int = 0) {
        self.runs = runs
        self.listStyle = listStyle
        self.indentLevel = indentLevel
    }

    var plainText: String { runs.map(\.text).joined() }
}

public struct RichTextDocument: Equatable, Sendable, Codable {
    public var paragraphs: [RichTextParagraph]

    public init(paragraphs: [RichTextParagraph] = []) {
        self.paragraphs = paragraphs
    }

    /// Every prefill/quoting/template/signature path in `ComposerView` that
    /// inserts unformatted text (reply quoting, forward header block,
    /// mailto prefill, template/signature insertion, cancelled-send
    /// restore) goes through this — one plain run per `"\n"`-delimited
    /// line, no list/indent — so those flows keep producing exactly the
    /// same plain-text look they always have (this task's "既存機能を壊さな
    /// い" requirement), with only newly-typed/selected text ever picking
    /// up formatting.
    public static func plainText(_ text: String) -> RichTextDocument {
        guard !text.isEmpty else { return RichTextDocument(paragraphs: [RichTextParagraph(runs: [])]) }
        let lines = text.components(separatedBy: "\n")
        return RichTextDocument(paragraphs: lines.map { RichTextParagraph(runs: [RichTextRun(text: $0)]) })
    }

    /// The plain-text fallback derived from this document — what backs
    /// `DraftMessageRecord.plainTextBody`/`OutboxMessageRecord.plainTextBody`
    /// (persistence keeps storing plain text only; this task's HTML output
    /// is produced transiently at send time, never itself persisted — see
    /// `ComposerView`'s doc comment on the html/plain split) and the
    /// `multipart/alternative` `text/plain` part's content. List items get a
    /// synthesized `• `/`N. ` marker so a plain-text-only reader still sees
    /// a legible list instead of bare lines.
    public var plainText: String {
        var orderedCounters: [Int: Int] = [:]
        return paragraphs.map { paragraph -> String in
            switch paragraph.listStyle {
            case .none:
                return paragraph.plainText
            case .bullet:
                orderedCounters[paragraph.indentLevel] = 0
                return String(repeating: "  ", count: paragraph.indentLevel) + "• " + paragraph.plainText
            case .ordered:
                let next = (orderedCounters[paragraph.indentLevel] ?? 0) + 1
                orderedCounters[paragraph.indentLevel] = next
                return String(repeating: "  ", count: paragraph.indentLevel) + "\(next). " + paragraph.plainText
            }
        }.joined(separator: "\n")
    }
}
