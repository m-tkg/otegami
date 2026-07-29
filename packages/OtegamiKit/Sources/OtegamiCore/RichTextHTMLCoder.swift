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
/// `del`, `ul`/`ol`/`li`, `blockquote`, `br`), so round-tripping our own
/// output is exact; anything else (a pasted-in external HTML fragment) isn't
/// a case this stage needs to handle faithfully.
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
            return encoded
        }.joined()
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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

        for token in tokenize(html) {
            switch token {
            case .openTag(let name):
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
                default: break
                }
            case .text(let text):
                guard isInsideParagraphOrItem, !text.isEmpty else { continue }
                currentRuns.append(RichTextRun(
                    text: text, isBold: boldDepth > 0, isItalic: italicDepth > 0,
                    isUnderline: underlineDepth > 0, isStrikethrough: strikeDepth > 0
                ))
            }
        }

        return RichTextDocument(paragraphs: paragraphs.isEmpty ? [RichTextParagraph(runs: [])] : paragraphs)
    }

    // MARK: - Tokenizer

    private enum Token {
        case openTag(String)
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
                    tokens.append(.closeTag(String(inner.dropFirst()).lowercased()))
                } else {
                    // Tag name only — our own output never has attributes,
                    // but split on whitespace defensively anyway, and trim a
                    // trailing "/" for self-closing tags (`<br/>`).
                    let name = inner.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                    tokens.append(.openTag(name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()))
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

    /// Small duplicate of `HTMLTextExtractor`'s entity table rather than a
    /// shared helper — this coder only ever needs to decode the handful of
    /// entities its own `escape(_:)` produces (`&amp;`/`&lt;`/`&gt;`) plus
    /// the common ones a hand-typed HTML fragment might contain; keeping it
    /// local avoids coupling two otherwise-independent parsers together for
    /// a dozen lines of table lookup.
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
