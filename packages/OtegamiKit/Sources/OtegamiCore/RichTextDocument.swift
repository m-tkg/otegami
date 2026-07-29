import Foundation

/// Task #161 (#129 第2段): a run's font size, as a small preset ladder rather
/// than an arbitrary point/pixel value — matches the plan's "フォントサイズ
/// 選択 (小/標準/大/特大 程度のプリセットで十分)". `.standard` is the baseline
/// (whatever the body font's own size already is, no override) and is
/// deliberately never emitted as an explicit `font-size` in HTML
/// (`RichTextHTMLCoder.encodeRuns(_:)`) — only a non-standard pick produces
/// an inline style, keeping the common case's markup exactly as small as
/// before this task.
public enum RichTextFontSize: String, Equatable, Sendable, Codable, CaseIterable {
    case small
    case standard
    case large
    case xlarge

    /// The `font-size:Npx` value this size encodes to — also what
    /// `nearestPixelSize(_:)` matches back against when decoding an
    /// arbitrary `font-size` HTML wrote (this coder's own output always
    /// round-trips exactly; a value in between two presets rounds to the
    /// closer one rather than failing to decode at all).
    public var pixelSize: Int {
        switch self {
        case .small: 13
        case .standard: 16
        case .large: 20
        case .xlarge: 26
        }
    }

    /// The nearest preset to an arbitrary pixel size (e.g. `20` from a
    /// decoded `font-size:20px`) — nearest-neighbor on `pixelSize`, ties
    /// broken toward the smaller preset.
    public static func nearest(toPixelSize pixelSize: Int) -> RichTextFontSize {
        allCases.min { lhs, rhs in
            let lhsDelta = abs(lhs.pixelSize - pixelSize)
            let rhsDelta = abs(rhs.pixelSize - pixelSize)
            return lhsDelta == rhsDelta ? lhs.pixelSize < rhs.pixelSize : lhsDelta < rhsDelta
        } ?? .standard
    }
}

/// Task #161 (#129 第2段): a small preset palette for 文字色/背景色 (ハイライト)
/// — "DesignSystem トークンと衝突しない、メール本文用の標準色" from the plan,
/// i.e. deliberately *not* `OtegamiColor` (that palette is UI chrome, tied to
/// light/dark appearance; a color the user explicitly paints onto body text
/// has to render the same, unchanging way in every recipient's mail client,
/// light or dark, this app or any other — the same reasoning `docs/design-
/// system.md`'s dark-mode HTML-rendering notes give for why a message's own
/// explicit colors are left alone). Same small set doubles as both the text-
/// color and highlight/background-color swatch list (`RichTextFormattingBar`)
/// — most simple rich text composers (Spark included) share one palette
/// between the two pickers rather than maintaining two independent ones.
public enum RichTextColor: String, Equatable, Sendable, Codable, CaseIterable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray

    /// The exact `#rrggbb` this encodes to in HTML (`color:`/`background-
    /// color:` inline style) — fixed hex, not derived from any `Color`/
    /// `UIColor`/`NSColor` API, so it never shifts with system appearance.
    public var hex: String {
        switch self {
        case .red: "#d93025"
        case .orange: "#e8710a"
        case .yellow: "#f9ab00"
        case .green: "#1e8e3e"
        case .blue: "#1a73e8"
        case .purple: "#8430ce"
        case .gray: "#5f6368"
        }
    }

    /// The reverse of `hex` — used decoding a `color`/`background-color`
    /// HTML wrote back into a preset, matching by exact hex string (case-
    /// insensitive; this coder's own output is always lowercase, but a
    /// defensive match costs nothing). `nil` for any hex this palette
    /// doesn't contain — decoding falls back to dropping the color rather
    /// than inventing a preset that isn't one of these seven.
    public static func matching(hex: String) -> RichTextColor? {
        let normalized = hex.lowercased()
        return allCases.first { $0.hex == normalized }
    }
}

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
    /// Task #161: `.standard` (the default) never emits a `font-size` —
    /// see `RichTextFontSize`'s doc comment.
    public var fontSize: RichTextFontSize
    /// Task #161: `nil` = no explicit color (inherits whatever the reading
    /// client's own default text color is) — matches `isBold`/etc.'s
    /// "absence of the flag means untouched" shape rather than always
    /// carrying some `RichTextColor` default.
    public var textColor: RichTextColor?
    /// Task #161: 背景色/ハイライト — same "`nil` = none" shape as `textColor`.
    public var backgroundColor: RichTextColor?
    /// Task #161: the URL this run links to, if any — plain `String` (not
    /// `URL`) since an in-progress edit may briefly hold something that
    /// isn't yet a valid URL, and the HTML encoder only needs to
    /// attribute-escape it, never parse it.
    public var linkURL: String?

    public init(
        text: String,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderline: Bool = false,
        isStrikethrough: Bool = false,
        fontSize: RichTextFontSize = .standard,
        textColor: RichTextColor? = nil,
        backgroundColor: RichTextColor? = nil,
        linkURL: String? = nil
    ) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.isStrikethrough = isStrikethrough
        self.fontSize = fontSize
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.linkURL = linkURL
    }

    /// Whether this run carries no formatting at all — used by the HTML
    /// encoder to skip wrapping plain runs in any inline tag, and by the
    /// plain-text deriver (nothing to strip either way).
    var isPlain: Bool {
        !isBold && !isItalic && !isUnderline && !isStrikethrough
            && fontSize == .standard && textColor == nil && backgroundColor == nil && linkURL == nil
    }
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

    /// Task #162 (実機フィードバック「署名が本文に混ざって編集しづらい」):
    /// combines this (editable, persisted) body with a signature template's
    /// body as "本文 + 空行 + 署名" — a blank-line paragraph, then one plain
    /// paragraph per line of `signatureBody` (`plainText(_:)`'s "one plain
    /// run per line" shape, since a signature template's body is itself
    /// plain text, `SignatureTemplateRecord.body: String`, never rich text).
    /// `nil`/empty `signatureBody` returns `self` unchanged (no trailing
    /// blank line added when there's nothing to append).
    ///
    /// Deliberately the *only* place body and signature ever combine —
    /// `ComposerView.send()`'s sole caller, right before deriving both the
    /// `plainText` and `RichTextHTMLCoder.encode(_:)` representations for
    /// `OutboxMessageRecord`. Building one combined `RichTextDocument` and
    /// deriving both representations from it (rather than hand-splicing two
    /// independently-produced plain/HTML strings) guarantees the two never
    /// drift out of sync with each other. Every other body/signature
    /// consumer (the Composer's own editor, `DraftMessageRecord`, C7's
    /// `PendingSendDraftSnapshot`) keeps body and signature choice
    /// (`selectedSignatureId`) entirely separate — see `ComposerView`'s
    /// "MARK: - F 署名" doc comment for the full picture of why.
    public func appendingSignature(_ signatureBody: String?) -> RichTextDocument {
        guard let signatureBody, !signatureBody.isEmpty else { return self }
        var combined = self
        combined.paragraphs.append(RichTextParagraph(runs: []))
        combined.paragraphs.append(contentsOf: RichTextDocument.plainText(signatureBody).paragraphs)
        return combined
    }
}
