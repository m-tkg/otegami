import Foundation
import OtegamiCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

#if os(iOS)
typealias PlatformFont = UIFont
#else
typealias PlatformFont = NSFont
#endif

/// Task #129 (作成画面リッチテキスト化): everything that bridges the real
/// `NSAttributedString` `RichTextEditor`'s `UITextView`/`NSTextView` edits
/// to/from `OtegamiCore.RichTextDocument` — the pure model
/// `RichTextHTMLCoder` serializes to HTML at send time. Kept out of
/// `OtegamiCore` deliberately (that package stays UIKit/AppKit-free — see
/// `RichTextDocument`'s doc comment); this file is the one place platform
/// font/attribute types are allowed to appear for this feature.
///
/// Formatting representation on the live `NSAttributedString`:
/// - bold/italic: real symbolic font traits on `.font` (so the editor is
///   genuinely WYSIWYG, not just a hidden semantic flag).
/// - underline/strikethrough: the standard `.underlineStyle`/
///   `.strikethroughStyle` attributes (plain `NSNumber`s — no platform type
///   involved, but grouped here for one bold/italic/underline/strikethrough
///   toggle surface).
/// - list/indent: `NSParagraphStyle.textLists` (`[NSTextList]`, 0 or 1
///   elements) plus `.headIndent`/`.firstLineHeadIndent` for both the visual
///   hanging indent and (via `indentUnit`) this feature's indent level —
///   `NSTextList` renders its own marker (bullet/number) at layout time, so
///   list items never need literal "•"/"1." characters inserted into the
///   string itself, which would otherwise have to be tracked and stripped
///   back out for `RichTextDocument` (and would drift out of sync with
///   arbitrary edits).
enum RichTextAttributedString {
    /// One indent level's width. Only this file's own read (`documentIndentLevel`)
    /// and write (`applyParagraphStyle`) sides need to agree on it.
    static let indentUnit: CGFloat = 24

    static var bodyFont: PlatformFont {
        #if os(iOS)
        .preferredFont(forTextStyle: .body)
        #else
        .systemFont(ofSize: NSFont.systemFontSize)
        #endif
    }

    /// Every prefill/quote/template/signature insertion point in
    /// `ComposerView` that used to just set a plain `String` now builds its
    /// replacement text through this — a single explicit `.font` (this
    /// feature's baseline) across the whole string, no bold/italic/
    /// underline/strikethrough/list/indent. Explicit rather than leaving
    /// `.font` unset: every formatting toggle below reads the *current*
    /// font at a location to decide the next trait set, and an unset
    /// attribute would need special-casing everywhere instead of a single
    /// known baseline.
    static func plainAttributedString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: bodyFont])
    }

    // MARK: - NSAttributedString → RichTextDocument (send-time HTML encode)

    static func makeDocument(from attributedString: NSAttributedString) -> RichTextDocument {
        let string = attributedString.string as NSString
        guard string.length > 0 else { return RichTextDocument(paragraphs: [RichTextParagraph(runs: [])]) }

        var paragraphs: [RichTextParagraph] = []
        var searchLocation = 0
        while searchLocation <= string.length {
            let paragraphRange = string.paragraphRange(for: NSRange(location: searchLocation, length: 0))
            paragraphs.append(makeParagraph(from: attributedString, paragraphRange: paragraphRange, string: string))
            let nextLocation = paragraphRange.location + paragraphRange.length
            if nextLocation > searchLocation {
                searchLocation = nextLocation
            } else {
                break // Defensive: `paragraphRange` didn't advance — avoid looping forever.
            }
        }
        return RichTextDocument(paragraphs: paragraphs)
    }

    private static func makeParagraph(from attributedString: NSAttributedString, paragraphRange: NSRange, string: NSString) -> RichTextParagraph {
        // `paragraphRange(for:)` includes the trailing "\n" — excluded here
        // so run text never carries a literal newline (paragraphs already
        // encode the line break structurally, both in `RichTextDocument`
        // and in `RichTextHTMLCoder`'s output).
        var contentLength = paragraphRange.length
        if contentLength > 0, string.character(at: paragraphRange.location + contentLength - 1) == 0x0A {
            contentLength -= 1
        }
        let contentRange = NSRange(location: paragraphRange.location, length: contentLength)

        let paragraphStyle = contentLength > 0
            ? attributedString.attribute(.paragraphStyle, at: contentRange.location, effectiveRange: nil) as? NSParagraphStyle
            : nil
        let (listStyle, indentLevel) = documentListStyleAndIndent(from: paragraphStyle)

        guard contentLength > 0 else {
            return RichTextParagraph(runs: [], listStyle: listStyle, indentLevel: indentLevel)
        }

        var runs: [RichTextRun] = []
        attributedString.enumerateAttributes(in: contentRange, options: []) { attributes, range, _ in
            let text = string.substring(with: range)
            guard !text.isEmpty else { return }
            let font = attributes[.font] as? PlatformFont
            let underline = (attributes[.underlineStyle] as? Int) ?? 0
            let strikethrough = (attributes[.strikethroughStyle] as? Int) ?? 0
            runs.append(RichTextRun(
                text: text,
                isBold: font.map(isBold) ?? false,
                isItalic: font.map(isItalic) ?? false,
                isUnderline: underline != 0,
                isStrikethrough: strikethrough != 0
            ))
        }
        return RichTextParagraph(runs: runs, listStyle: listStyle, indentLevel: indentLevel)
    }

    private static func documentListStyleAndIndent(from paragraphStyle: NSParagraphStyle?) -> (RichTextListStyle, Int) {
        guard let paragraphStyle else { return (.none, 0) }
        let listStyle: RichTextListStyle
        if let textList = paragraphStyle.textLists.first {
            listStyle = textList.markerFormat == .decimal ? .ordered : .bullet
        } else {
            listStyle = .none
        }
        let level = Int((paragraphStyle.firstLineHeadIndent / indentUnit).rounded())
        return (listStyle, max(0, level))
    }

    // MARK: - Font trait helpers

    static func isBold(_ font: PlatformFont) -> Bool {
        #if os(iOS)
        font.fontDescriptor.symbolicTraits.contains(.traitBold)
        #else
        font.fontDescriptor.symbolicTraits.contains(.bold)
        #endif
    }

    static func isItalic(_ font: PlatformFont) -> Bool {
        #if os(iOS)
        font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        #else
        font.fontDescriptor.symbolicTraits.contains(.italic)
        #endif
    }

    /// Returns `font` with the bold trait turned on/off, preserving every
    /// other trait (italic in particular — bold and italic toggle
    /// independently). Falls back to `font` unchanged if the platform can't
    /// resolve a font matching the requested trait combination (defensive;
    /// doesn't happen for the system font this editor uses as its baseline).
    static func settingBold(_ enabled: Bool, on font: PlatformFont) -> PlatformFont {
        #if os(iOS)
        var traits = font.fontDescriptor.symbolicTraits
        if enabled { traits.insert(.traitBold) } else { traits.remove(.traitBold) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #else
        var traits = font.fontDescriptor.symbolicTraits
        if enabled { traits.insert(.bold) } else { traits.remove(.bold) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #endif
    }

    static func settingItalic(_ enabled: Bool, on font: PlatformFont) -> PlatformFont {
        #if os(iOS)
        var traits = font.fontDescriptor.symbolicTraits
        if enabled { traits.insert(.traitItalic) } else { traits.remove(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #else
        var traits = font.fontDescriptor.symbolicTraits
        if enabled { traits.insert(.italic) } else { traits.remove(.italic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #endif
    }

    // MARK: - Paragraph style (list / indent)

    /// Builds the `NSParagraphStyle` for a paragraph at `listStyle`/
    /// `indentLevel` — a hanging indent when it's a list item (the marker
    /// sits at `firstLineHeadIndent`, the wrapped text body at `headIndent`,
    /// standard list-layout convention), a flush indent otherwise.
    static func paragraphStyle(listStyle: RichTextListStyle, indentLevel: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let base = CGFloat(max(0, indentLevel)) * indentUnit
        switch listStyle {
        case .none:
            style.firstLineHeadIndent = base
            style.headIndent = base
            style.textLists = []
        case .bullet, .ordered:
            style.firstLineHeadIndent = base
            style.headIndent = base + indentUnit
            style.textLists = [NSTextList(markerFormat: listStyle == .ordered ? .decimal : .disc, options: 0)]
        }
        return style
    }
}

// MARK: - Formatting commands (formatting bar → live NSMutableAttributedString)

extension RichTextAttributedString {
    /// What the formatting bar should show as "currently active" for
    /// wherever `selectedRange` is. Mirrors the standard rich-editor
    /// convention: a non-empty selection reports a trait as active only if
    /// *every* character in it has that trait (matching `isBoldUniform`
    /// etc. below, which the toggle commands use to decide on/off); an
    /// empty selection (just a cursor) reports the character immediately
    /// before it (i.e. what continuing to type would inherit) — falling
    /// back to the character after, then to the document's blank-state
    /// default, so an empty document or a cursor at its very start still
    /// resolves to *something* rather than crashing on an out-of-bounds
    /// index.
    static func typingState(in attributedString: NSAttributedString, selectedRange: NSRange) -> RichTextTypingState {
        let length = attributedString.length
        guard length > 0 else { return RichTextTypingState() }
        if selectedRange.length > 0 {
            let (listStyle, indentLevel) = paragraphListStyleAndIndent(at: selectedRange.location, in: attributedString)
            return RichTextTypingState(
                isBold: isBoldUniform(in: attributedString, range: selectedRange),
                isItalic: isItalicUniform(in: attributedString, range: selectedRange),
                isUnderline: isUnderlineUniform(in: attributedString, range: selectedRange),
                isStrikethrough: isStrikethroughUniform(in: attributedString, range: selectedRange),
                listStyle: listStyle,
                indentLevel: indentLevel
            )
        }
        let index = selectedRange.location > 0 ? selectedRange.location - 1 : 0
        let clampedIndex = min(index, length - 1)
        let attributes = attributedString.attributes(at: clampedIndex, effectiveRange: nil)
        let font = attributes[.font] as? PlatformFont
        let underline = (attributes[.underlineStyle] as? Int) ?? 0
        let strikethrough = (attributes[.strikethroughStyle] as? Int) ?? 0
        let (listStyle, indentLevel) = documentListStyleAndIndent(from: attributes[.paragraphStyle] as? NSParagraphStyle)
        return RichTextTypingState(
            isBold: font.map(isBold) ?? false,
            isItalic: font.map(isItalic) ?? false,
            isUnderline: underline != 0,
            isStrikethrough: strikethrough != 0,
            listStyle: listStyle,
            indentLevel: indentLevel
        )
    }

    private static func paragraphListStyleAndIndent(at location: Int, in attributedString: NSAttributedString) -> (RichTextListStyle, Int) {
        guard attributedString.length > 0 else { return (.none, 0) }
        let clamped = min(location, attributedString.length - 1)
        let style = attributedString.attribute(.paragraphStyle, at: clamped, effectiveRange: nil) as? NSParagraphStyle
        return documentListStyleAndIndent(from: style)
    }

    static func isBoldUniform(in attributedString: NSAttributedString, range: NSRange) -> Bool {
        isFontTraitUniform(in: attributedString, range: range, satisfies: isBold)
    }

    static func isItalicUniform(in attributedString: NSAttributedString, range: NSRange) -> Bool {
        isFontTraitUniform(in: attributedString, range: range, satisfies: isItalic)
    }

    private static func isFontTraitUniform(in attributedString: NSAttributedString, range: NSRange, satisfies predicate: (PlatformFont) -> Bool) -> Bool {
        guard range.length > 0 else { return false }
        var uniform = true
        attributedString.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
            guard let font = value as? PlatformFont, predicate(font) else {
                uniform = false
                stop.pointee = true
                return
            }
        }
        return uniform
    }

    static func isUnderlineUniform(in attributedString: NSAttributedString, range: NSRange) -> Bool {
        isIntAttributeUniform(.underlineStyle, in: attributedString, range: range)
    }

    static func isStrikethroughUniform(in attributedString: NSAttributedString, range: NSRange) -> Bool {
        isIntAttributeUniform(.strikethroughStyle, in: attributedString, range: range)
    }

    private static func isIntAttributeUniform(_ key: NSAttributedString.Key, in attributedString: NSAttributedString, range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        var uniform = true
        attributedString.enumerateAttribute(key, in: range, options: []) { value, _, stop in
            guard let raw = value as? Int, raw != 0 else {
                uniform = false
                stop.pointee = true
                return
            }
        }
        return uniform
    }

    // MARK: - Inline toggles

    static func applyBold(_ enabled: Bool, to attributedString: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        attributedString.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let font = (value as? PlatformFont) ?? bodyFont
            attributedString.addAttribute(.font, value: settingBold(enabled, on: font), range: subrange)
        }
    }

    static func applyItalic(_ enabled: Bool, to attributedString: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        attributedString.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let font = (value as? PlatformFont) ?? bodyFont
            attributedString.addAttribute(.font, value: settingItalic(enabled, on: font), range: subrange)
        }
    }

    static func applyUnderline(_ enabled: Bool, to attributedString: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        if enabled {
            attributedString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        } else {
            attributedString.removeAttribute(.underlineStyle, range: range)
        }
    }

    static func applyStrikethrough(_ enabled: Bool, to attributedString: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        if enabled {
            attributedString.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        } else {
            attributedString.removeAttribute(.strikethroughStyle, range: range)
        }
    }

    /// Strips every inline/paragraph formatting this feature applies from
    /// `range` — bold/italic/underline/strikethrough, and (for whichever
    /// paragraphs `range` touches) list membership and indent. Leaves the
    /// text itself, and the font's base size/family, untouched.
    static func clearFormatting(to attributedString: NSMutableAttributedString, range: NSRange) {
        if range.length > 0 {
            attributedString.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                let font = (value as? PlatformFont) ?? bodyFont
                var plain = settingBold(false, on: font)
                plain = settingItalic(false, on: plain)
                attributedString.addAttribute(.font, value: plain, range: subrange)
            }
            attributedString.removeAttribute(.underlineStyle, range: range)
            attributedString.removeAttribute(.strikethroughStyle, range: range)
        }
        guard attributedString.length > 0 else { return }
        for paragraphRange in paragraphRanges(coveringSelection: range, in: attributedString) {
            attributedString.addAttribute(.paragraphStyle, value: paragraphStyle(listStyle: .none, indentLevel: 0), range: paragraphRange)
        }
    }

    // MARK: - Paragraph-level commands (list / indent)

    /// Every paragraph `range` touches: turns `style` on if any touched
    /// paragraph doesn't already have it, off (back to `.none`) only when
    /// *all* of them already do — the same "not-yet-uniform → apply,
    /// already-uniform → remove" toggle convention `isBoldUniform`/etc. use
    /// for inline formatting.
    static func applyList(_ style: RichTextListStyle, to attributedString: NSMutableAttributedString, range: NSRange) {
        guard attributedString.length > 0 else { return }
        let paragraphRanges = paragraphRanges(coveringSelection: range, in: attributedString)
        guard !paragraphRanges.isEmpty else { return }
        let allAlreadyThisStyle = paragraphRanges.allSatisfy { paragraphRange in
            paragraphListStyleAndIndent(at: paragraphRange.location, in: attributedString).0 == style
        }
        let newStyle: RichTextListStyle = allAlreadyThisStyle ? .none : style
        for paragraphRange in paragraphRanges {
            let indentLevel = paragraphListStyleAndIndent(at: paragraphRange.location, in: attributedString).1
            attributedString.addAttribute(.paragraphStyle, value: paragraphStyle(listStyle: newStyle, indentLevel: indentLevel), range: paragraphRange)
        }
    }

    /// `delta` is `+1`/`-1` per formatting-bar indent button tap — applied
    /// to every paragraph `range` touches, clamped to `0` (can't out-dent
    /// past the left margin).
    static func applyIndent(by delta: Int, to attributedString: NSMutableAttributedString, range: NSRange) {
        guard attributedString.length > 0 else { return }
        for paragraphRange in paragraphRanges(coveringSelection: range, in: attributedString) {
            let (listStyle, indentLevel) = paragraphListStyleAndIndent(at: paragraphRange.location, in: attributedString)
            let newLevel = max(0, indentLevel + delta)
            attributedString.addAttribute(.paragraphStyle, value: paragraphStyle(listStyle: listStyle, indentLevel: newLevel), range: paragraphRange)
        }
    }

    /// Every whole paragraph `range` overlaps, as ranges *including* each
    /// paragraph's terminating `"\n"` (so a `.paragraphStyle` attribute
    /// applied to one of these ranges governs the complete paragraph, not
    /// just its content) — built from `NSString.paragraphRange(for:)`
    /// extending `range` to full paragraph boundaries, then
    /// `enumerateSubstrings(options:.byParagraphs)` to split that back into
    /// individual paragraphs when `range` spans more than one.
    private static func paragraphRanges(coveringSelection range: NSRange, in attributedString: NSAttributedString) -> [NSRange] {
        let string = attributedString.string as NSString
        guard string.length > 0 else { return [] }
        let clampedLocation = min(max(0, range.location), string.length)
        let clampedLength = min(max(0, range.length), string.length - clampedLocation)
        let clamped = NSRange(location: clampedLocation, length: clampedLength)
        let fullRange = string.paragraphRange(for: clamped)
        var ranges: [NSRange] = []
        string.enumerateSubstrings(in: fullRange, options: .byParagraphs) { _, _, enclosingRange, _ in
            ranges.append(enclosingRange)
        }
        return ranges.isEmpty ? [fullRange] : ranges
    }
}
