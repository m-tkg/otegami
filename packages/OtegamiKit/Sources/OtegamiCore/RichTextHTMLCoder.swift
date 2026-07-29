import Foundation

/// Task #129 (作成画面リッチテキスト化): converts `RichTextDocument` ⇄ HTML —
/// the piece `ComposerView.send()` uses to turn the composed body into the
/// `text/html` part of a `multipart/alternative` send
/// (`MailCoreMessageBuilder.build` sets both `textBody` and `htmlBody`),
/// and what the "各書式のラウンドトリップ" unit tests exercise directly.
///
/// Deliberately a small hand-rolled tokenizer/encoder (same "dependency-free,
/// pure Swift" shape as `HTMLTextExtractor`), not a general HTML5 parser —
/// `decode(html:)` only needs to understand the exact tag vocabulary
/// `encode(_:)` itself emits (`p`, `b`/`strong`, `i`/`em`, `u`, `s`/`strike`/
/// `del`, `ul`/`ol`/`li`, `blockquote`, `br`, `span`/`a` with a `style`/`href`
/// attribute — Task #161's フォントサイズ/文字色/背景色/リンク extension), so
/// round-tripping our own output is exact; anything else (a pasted-in
/// external HTML fragment) isn't a case this stage needs to handle
/// faithfully.
public enum RichTextHTMLCoder {
    // MARK: - Encode

    public static func encode(_ document: RichTextDocument) -> String {
        var html = ""
        var index = 0
        let paragraphs = document.paragraphs
        while index < paragraphs.count {
            let paragraph = paragraphs[index]
            if paragraph.listStyle == .none {
                html += String(repeating: "<blockquote>", count: paragraph.indentLevel)
                html += "<p>\(encodeRuns(paragraph.runs))</p>"
                html += String(repeating: "</blockquote>", count: paragraph.indentLevel)
                index += 1
                continue
            }

            // Consecutive paragraphs sharing the same list style and indent
            // become one `<ul>`/`<ol>` — required for `<ol>` numbering to
            // render correctly at all (a run of single-item `<ol>`s would
            // each restart at "1.").
            let style = paragraph.listStyle
            let indent = paragraph.indentLevel
            var items: [String] = []
            while index < paragraphs.count, paragraphs[index].listStyle == style, paragraphs[index].indentLevel == indent {
                items.append("<li>\(encodeRuns(paragraphs[index].runs))</li>")
                index += 1
            }
            let tag = style == .ordered ? "ol" : "ul"
            html += String(repeating: "<blockquote>", count: indent)
            html += "<\(tag)>\(items.joined())</\(tag)>"
            html += String(repeating: "</blockquote>", count: indent)
        }
        return html
    }

    private static func encodeRuns(_ runs: [RichTextRun]) -> String {
        guard !runs.allSatisfy({ $0.text.isEmpty }) else {
            // An empty paragraph (blank line) — `<p></p>` collapses to
            // nothing visible in most mail clients, `<br>` preserves it.
            return "<br>"
        }
        return runs.map { run -> String in
            guard !run.text.isEmpty else { return "" }
            var encoded = escape(run.text)
            if run.isBold { encoded = "<b>\(encoded)</b>" }
            if run.isItalic { encoded = "<i>\(encoded)</i>" }
            if run.isUnderline { encoded = "<u>\(encoded)</u>" }
            if run.isStrikethrough { encoded = "<s>\(encoded)</s>" }
            let style = styleDeclaration(for: run)
            if let linkURL = run.linkURL, !linkURL.isEmpty {
                // Task #161: style lives directly on the `<a>` itself
                // (rather than an extra nested `<span>`) — one fewer tag
                // level, and still a shape plenty of real-world mail HTML
                // uses (`<a href="..." style="color:...">`).
                let styleAttribute = style.map { " style=\"\($0)\"" } ?? ""
                encoded = "<a href=\"\(escapeAttribute(linkURL))\"\(styleAttribute)>\(encoded)</a>"
            } else if let style {
                encoded = "<span style=\"\(style)\">\(encoded)</span>"
            }
            return encoded
        }.joined()
    }

    /// Task #161: the combined `font-size`/`color`/`background-color`
    /// inline style declarations this run needs, or `nil` if it needs none
    /// (the common case — `.standard` size, no explicit color/highlight).
    /// Order is fixed (font-size, then color, then background-color) so
    /// encoding the same run always produces byte-identical HTML.
    private static func styleDeclaration(for run: RichTextRun) -> String? {
        var declarations: [String] = []
        if run.fontSize != .standard { declarations.append("font-size:\(run.fontSize.pixelSize)px") }
        if let textColor = run.textColor { declarations.append("color:\(textColor.hex)") }
        if let backgroundColor = run.backgroundColor { declarations.append("background-color:\(backgroundColor.hex)") }
        return declarations.isEmpty ? nil : declarations.joined(separator: ";")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Same as `escape(_:)`, plus `"` — this coder's own attribute values
    /// (`href`, `style`) are always written inside double quotes, so a
    /// quote inside the URL itself has to be escaped or it would prematurely
    /// close the attribute.
    private static func escapeAttribute(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Decode

    public static func decode(html: String) -> RichTextDocument {
        var paragraphs: [RichTextParagraph] = []
        var blockquoteDepth = 0
        var listStyleStack: [RichTextListStyle] = []
        var currentRuns: [RichTextRun] = []
        var boldDepth = 0
        var italicDepth = 0
        var underlineDepth = 0
        var strikeDepth = 0
        var isInsideParagraphOrItem = false

        // Task #161: `span`/`a` style state — `fontSizeStack`/`colorStack`/
        // `backgroundStack` hold the pixel-size/hex value each currently-open
        // tag contributed (innermost/last wins, same "depth stack" shape as
        // `boldDepth` etc., just carrying a value instead of a count);
        // `styleFrameStack` records, per open `span`/`a`, which of those
        // three stacks it actually pushed to (a tag might set only one of
        // the three, or none), so the matching close pops exactly what was
        // pushed. `linkStack` is `a`'s own `href` — tracked separately since
        // it isn't a style declaration.
        var fontSizeStack: [Int] = []
        var colorStack: [String] = []
        var backgroundStack: [String] = []
        var linkStack: [String] = []
        struct StyleFrame {
            var pushedFontSize = false
            var pushedColor = false
            var pushedBackground = false
        }
        var styleFrameStack: [StyleFrame] = []

        for token in tokenize(html) {
            switch token {
            case .openTag(let name, let attributes):
                switch name {
                case "blockquote": blockquoteDepth += 1
                case "ul": listStyleStack.append(.bullet)
                case "ol": listStyleStack.append(.ordered)
                case "p", "li":
                    currentRuns = []
                    isInsideParagraphOrItem = true
                case "b", "strong": boldDepth += 1
                case "i", "em": italicDepth += 1
                case "u": underlineDepth += 1
                case "s", "strike", "del": strikeDepth += 1
                case "span", "a":
                    if name == "a" { linkStack.append(attributes["href"] ?? "") }
                    let declarations = parseStyleDeclarations(attributes["style"] ?? "")
                    var frame = StyleFrame()
                    if let fontSizePixels = declarations.fontSizePixels {
                        fontSizeStack.append(fontSizePixels)
                        frame.pushedFontSize = true
                    }
                    if let colorHex = declarations.colorHex {
                        colorStack.append(colorHex)
                        frame.pushedColor = true
                    }
                    if let backgroundHex = declarations.backgroundHex {
                        backgroundStack.append(backgroundHex)
                        frame.pushedBackground = true
                    }
                    styleFrameStack.append(frame)
                default: break
                }
            case .closeTag(let name):
                switch name {
                case "blockquote": blockquoteDepth = max(0, blockquoteDepth - 1)
                case "ul", "ol": if !listStyleStack.isEmpty { listStyleStack.removeLast() }
                case "p", "li":
                    let style = name == "li" ? (listStyleStack.last ?? .none) : .none
                    paragraphs.append(RichTextParagraph(runs: currentRuns, listStyle: style, indentLevel: blockquoteDepth))
                    currentRuns = []
                    isInsideParagraphOrItem = false
                case "b", "strong": boldDepth = max(0, boldDepth - 1)
                case "i", "em": italicDepth = max(0, italicDepth - 1)
                case "u": underlineDepth = max(0, underlineDepth - 1)
                case "s", "strike", "del": strikeDepth = max(0, strikeDepth - 1)
                case "span", "a":
                    if name == "a", !linkStack.isEmpty { linkStack.removeLast() }
                    guard let frame = styleFrameStack.popLast() else { break }
                    if frame.pushedFontSize, !fontSizeStack.isEmpty { fontSizeStack.removeLast() }
                    if frame.pushedColor, !colorStack.isEmpty { colorStack.removeLast() }
                    if frame.pushedBackground, !backgroundStack.isEmpty { backgroundStack.removeLast() }
                default: break
                }
            case .text(let text):
                guard isInsideParagraphOrItem, !text.isEmpty else { continue }
                let fontSize = fontSizeStack.last.map(RichTextFontSize.nearest(toPixelSize:)) ?? .standard
                let textColor = colorStack.last.flatMap(RichTextColor.matching(hex:))
                let backgroundColor = backgroundStack.last.flatMap(RichTextColor.matching(hex:))
                let linkURL = linkStack.last.flatMap { $0.isEmpty ? nil : $0 }
                currentRuns.append(RichTextRun(
                    text: text, isBold: boldDepth > 0, isItalic: italicDepth > 0,
                    isUnderline: underlineDepth > 0, isStrikethrough: strikeDepth > 0,
                    fontSize: fontSize, textColor: textColor, backgroundColor: backgroundColor, linkURL: linkURL
                ))
            }
        }

        return RichTextDocument(paragraphs: paragraphs.isEmpty ? [RichTextParagraph(runs: [])] : paragraphs)
    }

    /// Task #161: parses a `style="..."` attribute value's `font-size`/
    /// `color`/`background-color` declarations (the only three this coder's
    /// own `encode(_:)` ever writes) — anything else in the string (there
    /// won't be anything else from this app's own output, but a defensively
    /// tolerant decoder costs nothing) is ignored rather than erroring.
    private static func parseStyleDeclarations(_ style: String) -> (fontSizePixels: Int?, colorHex: String?, backgroundHex: String?) {
        var fontSizePixels: Int?
        var colorHex: String?
        var backgroundHex: String?
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let property = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch property {
            case "font-size":
                guard value.hasSuffix("px"), let pixels = Int(value.dropLast(2)) else { continue }
                fontSizePixels = pixels
            case "color":
                colorHex = value.lowercased()
            case "background-color":
                backgroundHex = value.lowercased()
            default:
                break
            }
        }
        return (fontSizePixels, colorHex, backgroundHex)
    }

    // MARK: - Tokenizer

    private enum Token {
        case openTag(name: String, attributes: [String: String])
        case closeTag(String)
        case text(String)
    }

    private static func tokenize(_ html: String) -> [Token] {
        var tokens: [Token] = []
        var index = html.startIndex
        while index < html.endIndex {
            if html[index] == "<" {
                guard let closeBracket = html[index...].firstIndex(of: ">") else {
                    tokens.append(.text(decodeEntities(String(html[index...]))))
                    break
                }
                let inner = html[html.index(after: index)..<closeBracket]
                index = html.index(after: closeBracket)
                if inner.hasPrefix("/") {
                    tokens.append(.closeTag(String(inner.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()))
                } else {
                    let (name, attributes) = parseTag(inner)
                    tokens.append(.openTag(name: name, attributes: attributes))
                }
            } else {
                guard let nextTag = html[index...].firstIndex(of: "<") else {
                    let text = html[index...]
                    if !text.isEmpty { tokens.append(.text(decodeEntities(String(text)))) }
                    break
                }
                let text = html[index..<nextTag]
                if !text.isEmpty { tokens.append(.text(decodeEntities(String(text)))) }
                index = nextTag
            }
        }
        return tokens
    }

    /// Splits one open tag's inner text (everything between `<`/`>`,
    /// excluding a leading `/` for a close tag — those never reach this
    /// function) into its lowercased name and `key="value"` attributes.
    /// Task #161's `span`/`a` are the first tags this coder ever emits with
    /// attributes (`style`/`href`) — every earlier tag (`p`/`b`/`ul`/...)
    /// still round-trips through here with an empty attributes dictionary,
    /// same as before.
    private static func parseTag(_ inner: Substring) -> (name: String, attributes: [String: String]) {
        var trimmed = inner
        // Trailing "/" for a self-closing tag (`<br/>`, `<br />`) — none of
        // this coder's own attributed tags (`span`/`a`) are ever
        // self-closing, so this only ever fires for `br`.
        if trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard let firstSpace = trimmed.firstIndex(of: " ") else {
            return (trimmed.trimmingCharacters(in: .whitespaces).lowercased(), [:])
        }
        let name = trimmed[trimmed.startIndex..<firstSpace].lowercased()
        let attributesPart = trimmed[trimmed.index(after: firstSpace)...]
        return (name, parseAttributes(attributesPart))
    }

    /// Parses `key="value"` pairs out of a tag's attribute text. Only
    /// double-quoted values are recognized (the only form `encode(_:)` ever
    /// writes) — anything else (a bare/unquoted or single-quoted value)
    /// simply stops parsing at that point rather than guessing, since this
    /// coder never needs to understand attributes it didn't itself produce.
    private static func parseAttributes(_ text: Substring) -> [String: String] {
        var attributes: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
            guard index < text.endIndex, let equalsIndex = text[index...].firstIndex(of: "=") else { break }
            let key = text[index..<equalsIndex].trimmingCharacters(in: .whitespaces).lowercased()
            var valueStart = text.index(after: equalsIndex)
            guard valueStart < text.endIndex, text[valueStart] == "\"" else { break }
            valueStart = text.index(after: valueStart)
            guard let valueEnd = text[valueStart...].firstIndex(of: "\"") else { break }
            attributes[key] = decodeEntities(String(text[valueStart..<valueEnd]))
            index = text.index(after: valueEnd)
        }
        return attributes
    }

    /// Small duplicate of `HTMLTextExtractor`'s entity table rather than a
    /// shared helper — this coder only ever needs to decode the handful of
    /// entities its own `escape(_:)`/`escapeAttribute(_:)` produce
    /// (`&amp;`/`&lt;`/`&gt;`/`&quot;`) plus the common ones a hand-typed
    /// HTML fragment might contain; keeping it local avoids coupling two
    /// otherwise-independent parsers together for a dozen lines of table
    /// lookup.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
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
