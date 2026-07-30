import Foundation
import OtegamiCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

#if os(iOS)
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#else
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
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

    /// Task #178 (実機フィードバック「デフォルトにすると黒い文字になる」): the
    /// OS's own dynamic default text color — explicitly written into the
    /// live `NSAttributedString`/`typingAttributes` wherever `RichTextRun
    /// .textColor == nil` ("デフォルトの文字色"), rather than leaving the
    /// `.foregroundColor` attribute entirely absent (this file's approach
    /// before this task). Leaving it absent turned out not to survive a
    /// round trip through `UITextView`/`NSTextView`'s `typingAttributes` on
    /// device — once the user had touched `RichTextEditingController
    /// .setTextColor(_:)` at all, that API resynthesizes its own (non-
    /// dynamic) default for a missing `.foregroundColor` key instead of
    /// leaving it missing, so an attribute-less run could end up drawn in
    /// flat black even in Dark Mode. Writing this sentinel explicitly
    /// sidesteps that entirely — `.label`/`.labelColor` redraws correctly in
    /// either appearance no matter which code path last touched the
    /// attribute, and (unlike literal black) is never emitted as an HTML
    /// `color:` — `RichTextHTMLCoder.styleDeclaration(for:)` only fires for
    /// a non-`nil` `RichTextRun.textColor`, and `documentTextColor(from:)`
    /// below maps this sentinel back to `nil` before that ever happens.
    ///
    /// Distinguishing this sentinel from a user's *explicit* choice of
    /// `.black`/`.white` (Task #178 also added those two presets) relies on
    /// `PlatformColor.isEqual` comparing the dynamic *provider* itself, not
    /// a resolved snapshot in the current trait collection — this sentinel
    /// and a literal opaque black/white `UIColor`/`NSColor` never compare
    /// equal via `isEqual`, even though they can resolve to the identical
    /// RGB in a given appearance (light mode's `.label` is black; dark
    /// mode's is white). `documentTextColor(from:)` checks `isEqual` against
    /// this sentinel *first*, before ever falling through to `RichTextColor
    /// .matching(_:)`'s RGB-tolerance comparison, so this ambiguity never
    /// actually surfaces.
    static var defaultTextColor: PlatformColor {
        #if os(iOS)
        .label
        #else
        .labelColor
        #endif
    }

    /// Task #178: same reasoning as `defaultTextColor`, for 背景色/ハイライト's
    /// "ハイライトなし" — `.clear` written explicitly rather than an absent
    /// `.backgroundColor` attribute. No real-device report of a highlight-
    /// specific version of the text-color bug surfaced, but the same
    /// `typingAttributes` mechanism underlies both, so leaving this one
    /// implicit would be an unnecessary (and equally fragile) asymmetry.
    static var defaultBackgroundColor: PlatformColor { .clear }

    /// The reverse of writing `defaultTextColor`/a preset's `platformColor`
    /// onto `.foregroundColor` — what `RichTextRun.textColor`/`RichTextTypingState
    /// .textColor` should read back from a live attribute value. `nil` both
    /// when the attribute is entirely absent (defensive — every write site in
    /// this file always sets *something*, but decoded-then-rebuilt or
    /// otherwise externally-constructed attributed strings might not) and
    /// when it's this file's own `defaultTextColor` sentinel; falls through
    /// to `RichTextColor.matching(_:)` for anything else.
    ///
    /// Task #178: an *old* cancelled-send/draft snapshot that predates this
    /// task can legitimately carry a literal opaque black `.foregroundColor`
    /// — either because the user really had picked black under some other
    /// path, or as a fossil of the very `typingAttributes` bug this task
    /// fixes (see `defaultTextColor`'s doc comment). Once `.black` is a real
    /// preset, restoring that snapshot reads it back as `.black`, not `nil`
    /// — there is no way to tell those two histories apart after the fact,
    /// and treating it as the user's explicit choice (rather than silently
    /// "fixing" it back to default, which could just as easily undo a
    /// genuine choice) is the safer default.
    static func documentTextColor(from color: PlatformColor?) -> RichTextColor? {
        guard let color, !color.isEqual(defaultTextColor) else { return nil }
        return RichTextColor.matching(color)
    }

    /// The `.backgroundColor` counterpart of `documentTextColor(from:)`.
    static func documentBackgroundColor(from color: PlatformColor?) -> RichTextColor? {
        guard let color, !color.isEqual(defaultBackgroundColor) else { return nil }
        return RichTextColor.matching(color)
    }

    /// Every prefill/quote/template/signature insertion point in
    /// `ComposerView` that used to just set a plain `String` now builds its
    /// replacement text through this — a single explicit `.font`/
    /// `.foregroundColor` (this feature's baseline) across the whole string,
    /// no bold/italic/underline/strikethrough/list/indent. Explicit rather
    /// than leaving these unset: every formatting toggle below reads the
    /// *current* font/color at a location to decide the next value, and an
    /// unset attribute would need special-casing everywhere instead of a
    /// single known baseline — `.foregroundColor` joined `.font` here in
    /// Task #178 for exactly that reason (see `defaultTextColor`'s doc
    /// comment).
    static func plainAttributedString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: bodyFont, .foregroundColor: defaultTextColor])
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
                isStrikethrough: strikethrough != 0,
                fontSize: documentFontSize(from: font),
                textColor: documentTextColor(from: attributes[.foregroundColor] as? PlatformColor),
                backgroundColor: documentBackgroundColor(from: attributes[.backgroundColor] as? PlatformColor),
                linkURL: linkURLString(from: attributes[.link])
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

    // MARK: - RichTextDocument → NSAttributedString (C7 cancelled-send restore)

    /// The reverse of `makeDocument(from:)` — rebuilds a live, editable
    /// `NSAttributedString` from a `RichTextDocument` (typically one just
    /// decoded back out of HTML via `RichTextHTMLCoder.decode(html:)`).
    /// Task #156's only caller is `ComposerView.loadCancelledSend(_:)`
    /// (`PendingSendDraftSnapshot.htmlBody`'s doc comment) — reopening after
    /// "送信を取り消す" needs the exact formatting the user had applied, not
    /// just the plain-text projection `setPlainBody(_:)` would give it.
    ///
    /// Same lossy edge as `makeDocument(from:)`'s forward direction: an
    /// empty paragraph (blank line) never carries list/indent state either
    /// way (`documentListStyleAndIndent`'s `contentLength > 0` guard), so
    /// this doesn't bother attaching `.paragraphStyle` to a paragraph with
    /// no runs — there is nothing meaningful to restore for one.
    static func makeAttributedString(from document: RichTextDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, paragraph) in document.paragraphs.enumerated() {
            let style = paragraphStyle(listStyle: paragraph.listStyle, indentLevel: paragraph.indentLevel)
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
            }
            for run in paragraph.runs {
                guard !run.text.isEmpty else { continue }
                var font = settingBold(run.isBold, on: bodyFont)
                font = settingItalic(run.isItalic, on: font)
                font = settingFontSize(run.fontSize, on: font)
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
                if run.isUnderline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if run.isStrikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                // Task #178: always explicit (never left unset) — same
                // "known baseline, no absent-attribute special-casing"
                // reasoning as `plainAttributedString(_:)`, so a restored
                // cancelled-send run with no explicit color redraws
                // correctly in either appearance instead of risking the
                // `typingAttributes` default-color bug `defaultTextColor`'s
                // doc comment describes.
                attributes[.foregroundColor] = run.textColor?.platformColor ?? defaultTextColor
                attributes[.backgroundColor] = run.backgroundColor?.platformColor ?? defaultBackgroundColor
                if let linkURL = run.linkURL {
                    if let url = URL(string: linkURL) {
                        attributes[.link] = url
                    } else {
                        attributes[.link] = linkURL
                    }
                }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        guard result.length > 0 else {
            return NSAttributedString(string: "", attributes: [.font: bodyFont])
        }
        return result
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

    /// Task #161: which `RichTextFontSize` preset `font`'s point size is
    /// closest to — `.standard` for anything within half a point of
    /// `bodyFont.pointSize` (the un-overridden baseline), otherwise the
    /// nearest of the three explicit-size presets. `font == nil` (no
    /// `.font` attribute at all — shouldn't normally happen given
    /// `plainAttributedString(_:)` always sets one, but matches every
    /// other `font.map(...) ?? false`-style fallback in this file) also
    /// resolves to `.standard`.
    static func documentFontSize(from font: PlatformFont?) -> RichTextFontSize {
        guard let font else { return .standard }
        if abs(font.pointSize - bodyFont.pointSize) < 0.5 { return .standard }
        let overrides: [RichTextFontSize] = [.small, .large, .xlarge]
        return overrides.min { lhs, rhs in
            abs((lhs.pointSizeOverride ?? bodyFont.pointSize) - font.pointSize)
                < abs((rhs.pointSizeOverride ?? bodyFont.pointSize) - font.pointSize)
        } ?? .standard
    }

    /// Returns `font` at `size`'s point size (or `bodyFont`'s own size for
    /// `.standard`), preserving every symbolic trait (bold/italic) already
    /// on `font` — the same "rebuild the descriptor, keep everything else"
    /// shape `settingBold(_:on:)`/`settingItalic(_:on:)` use.
    static func settingFontSize(_ size: RichTextFontSize, on font: PlatformFont) -> PlatformFont {
        let pointSize = size.pointSizeOverride ?? bodyFont.pointSize
        #if os(iOS)
        return UIFont(descriptor: font.fontDescriptor, size: pointSize)
        #else
        return NSFont(descriptor: font.fontDescriptor, size: pointSize) ?? font
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

// MARK: - Font size / color bridging (Task #161, #129 第2段)

extension RichTextFontSize {
    /// The explicit point size this preset forces on the live
    /// `NSAttributedString` — `nil` for `.standard`, meaning "no override,
    /// keep whatever the base body font's own size already is" (so
    /// `.standard` stays Dynamic-Type-following, unlike the other three
    /// presets, which are fixed sizes by design — a deliberate, explicit
    /// choice the user made to size text away from the system default).
    /// Chosen to match `RichTextFontSize.pixelSize`'s HTML values 1:1
    /// (13/20/26pt ≈ 13/20/26px) — not a rigorous CSS px→pt conversion, but
    /// close enough that a formatted email looks the same size relationship
    /// on screen here as it will once sent.
    var pointSizeOverride: CGFloat? {
        switch self {
        case .standard: nil
        case .small: 13
        case .large: 20
        case .xlarge: 26
        }
    }
}

extension RichTextColor {
    /// The live `UIColor`/`NSColor` this preset paints onto the
    /// `NSAttributedString` — built from `hex` (never from a `Color`/
    /// `OtegamiColor` asset), so it never shifts with system appearance;
    /// see `RichTextColor`'s doc comment for why.
    var platformColor: PlatformColor {
        let sanitized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&rgb)
        return PlatformColor(
            red: CGFloat((rgb & 0xFF0000) >> 16) / 255,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255,
            blue: CGFloat(rgb & 0x0000FF) / 255,
            alpha: 1
        )
    }

    /// The reverse of `platformColor` — which preset (if any) `color`
    /// matches, compared component-by-component with a small tolerance
    /// (rather than object/pointer equality) since a color read back off
    /// `NSAttributedString` may have round-tripped through a different
    /// `NSColor`/`UIColor` color space than the one `platformColor` built
    /// it in. `nil` for any color that isn't one of this palette's presets —
    /// e.g. `nil` (no color) itself, never reached this far.
    static func matching(_ color: PlatformColor) -> RichTextColor? {
        allCases.first { candidate in colorsApproximatelyEqual(candidate.platformColor, color) }
    }
}

private func colorsApproximatelyEqual(_ lhs: PlatformColor, _ rhs: PlatformColor) -> Bool {
    #if os(iOS)
    var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
    var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
    guard lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la), rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra) else { return false }
    #else
    guard let lhsConverted = lhs.usingColorSpace(.deviceRGB), let rhsConverted = rhs.usingColorSpace(.deviceRGB) else { return false }
    let lr = lhsConverted.redComponent, lg = lhsConverted.greenComponent, lb = lhsConverted.blueComponent
    let la = lhsConverted.alphaComponent
    let rr = rhsConverted.redComponent, rg = rhsConverted.greenComponent, rb = rhsConverted.blueComponent
    let ra = rhsConverted.alphaComponent
    #endif
    let tolerance: CGFloat = 0.02
    return abs(lr - rr) < tolerance && abs(lg - rg) < tolerance && abs(lb - rb) < tolerance && abs(la - ra) < tolerance
}

/// Task #161: the `.link` attribute's value can legitimately be either a
/// `URL` or a bare `String` (`NSAttributedString.Key.link`'s documented
/// contract) — `applyLink(_:to:range:)` always writes a `URL` when the
/// string parses as one, but this reads either shape back, since a
/// collapsed-selection edit (`existingLinkRange(in:at:)`) reads whatever's
/// already there.
private func linkURLString(from value: Any?) -> String? {
    if let url = value as? URL { return url.absoluteString }
    if let string = value as? String, !string.isEmpty { return string }
    return nil
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
            // Task #161: fontSize/textColor/backgroundColor/linkURL read at
            // the selection's *start* only, same as `listStyle`/
            // `indentLevel` just above — not a whole-selection-uniform
            // check the way the four boolean inline traits below are. A
            // mixed-formatting selection just reflects its first
            // character's state, which is what the formatting bar then
            // highlights; harmless since applying a new value overwrites
            // the whole selection uniformly regardless.
            let attributes = attributedString.attributes(at: selectedRange.location, effectiveRange: nil)
            return RichTextTypingState(
                isBold: isBoldUniform(in: attributedString, range: selectedRange),
                isItalic: isItalicUniform(in: attributedString, range: selectedRange),
                isUnderline: isUnderlineUniform(in: attributedString, range: selectedRange),
                isStrikethrough: isStrikethroughUniform(in: attributedString, range: selectedRange),
                listStyle: listStyle,
                indentLevel: indentLevel,
                fontSize: documentFontSize(from: attributes[.font] as? PlatformFont),
                textColor: documentTextColor(from: attributes[.foregroundColor] as? PlatformColor),
                backgroundColor: documentBackgroundColor(from: attributes[.backgroundColor] as? PlatformColor),
                linkURL: linkURLString(from: attributes[.link])
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
            indentLevel: indentLevel,
            fontSize: documentFontSize(from: font),
            textColor: documentTextColor(from: attributes[.foregroundColor] as? PlatformColor),
            backgroundColor: documentBackgroundColor(from: attributes[.backgroundColor] as? PlatformColor),
            linkURL: linkURLString(from: attributes[.link])
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

    // MARK: - Font size / color / link (Task #161, #129 第2段)

    static func applyFontSize(_ size: RichTextFontSize, to attributedString: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        attributedString.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let font = (value as? PlatformFont) ?? bodyFont
            attributedString.addAttribute(.font, value: settingFontSize(size, on: font), range: subrange)
        }
    }

    /// Task #178: always writes an explicit value — `color`'s own
    /// `platformColor`, or `defaultTextColor` for "デフォルト" (`nil`) —
    /// rather than `removeAttribute`. Removing the attribute was this
    /// method's original approach and looked correct on paper (an
    /// attribute-less run *should* just inherit the text view's own default
    /// color), but didn't survive a `typingAttributes` round trip on device;
    /// see `defaultTextColor`'s doc comment for the full story (実機フィード
    /// バック 2026-07-30, Task #178).
    static func applyTextColor(_ color: RichTextColor?, to attributedString: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        attributedString.addAttribute(.foregroundColor, value: color?.platformColor ?? defaultTextColor, range: range)
    }

    /// Task #178: same "always explicit" reasoning as `applyTextColor(_:to:
    /// range:)`, using `defaultBackgroundColor` (`.clear`) for "ハイライトなし".
    static func applyBackgroundColor(_ color: RichTextColor?, to attributedString: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        attributedString.addAttribute(.backgroundColor, value: color?.platformColor ?? defaultBackgroundColor, range: range)
    }

    /// `urlString == nil` (or blank) removes the link from `range` instead
    /// of setting one. When adding a link, also forces underline on and —
    /// only where `range` doesn't already carry an explicit text color —
    /// defaults the color to `.blue`: the usual link affordance, expressed
    /// here as ordinary `RichTextRun` fields rather than a hidden
    /// "this-is-a-link-so-render-it-blue" special case elsewhere (the HTML
    /// encoder and every other reader of `RichTextDocument` just sees
    /// `isUnderline`/`textColor` like any other formatted run). Removing a
    /// link leaves whatever underline/color it had — same "leaves the rest
    /// of the formatting alone" contract `applyList`/`clearFormatting`
    /// already follow for their own attributes.
    static func applyLink(_ urlString: String?, to attributedString: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        guard let urlString, !urlString.trimmingCharacters(in: .whitespaces).isEmpty else {
            attributedString.removeAttribute(.link, range: range)
            return
        }
        if let url = URL(string: urlString) {
            attributedString.addAttribute(.link, value: url, range: range)
        } else {
            attributedString.addAttribute(.link, value: urlString, range: range)
        }
        attributedString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        // Task #178: "doesn't already carry an explicit text color" now
        // means `documentTextColor(from:)` resolves to `nil` (デフォルト),
        // not `value == nil` — every run's `.foregroundColor` is always
        // populated with *something* now (a preset or `defaultTextColor`),
        // so a raw `nil` check here would never fire and every link would
        // wrongly keep whatever non-color-explicit run it started from
        // instead of picking up the usual blue link color.
        attributedString.enumerateAttribute(.foregroundColor, in: range, options: []) { value, subrange, _ in
            guard documentTextColor(from: value as? PlatformColor) == nil else { return }
            attributedString.addAttribute(.foregroundColor, value: RichTextColor.blue.platformColor, range: subrange)
        }
    }

    /// The full effective range of the `.link` attribute at (or, failing
    /// that, immediately before) `location` — lets a collapsed selection
    /// (just a cursor) still edit/remove the link it's sitting inside,
    /// mirroring `typingState(in:selectedRange:)`'s own "check one
    /// character back too" cursor convention. `nil` when there's no link at
    /// either position — `setLink(_:)`'s collapsed-selection branch then
    /// has nothing to apply to and no-ops.
    static func existingLinkRange(in attributedString: NSAttributedString, at location: Int) -> NSRange? {
        guard attributedString.length > 0 else { return nil }
        let clamped = min(max(0, location), attributedString.length - 1)
        var effectiveRange = NSRange(location: 0, length: 0)
        if attributedString.attribute(.link, at: clamped, effectiveRange: &effectiveRange) != nil {
            return effectiveRange
        }
        guard clamped > 0, attributedString.attribute(.link, at: clamped - 1, effectiveRange: &effectiveRange) != nil else { return nil }
        return effectiveRange
    }

    /// Strips every inline/paragraph formatting this feature applies from
    /// `range` — bold/italic/underline/strikethrough/font size/text color/
    /// background color/link, and (for whichever paragraphs `range`
    /// touches) list membership and indent. Leaves the text itself, and
    /// the font's base family, untouched.
    static func clearFormatting(to attributedString: NSMutableAttributedString, range: NSRange) {
        if range.length > 0 {
            attributedString.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                let font = (value as? PlatformFont) ?? bodyFont
                var plain = settingBold(false, on: font)
                plain = settingItalic(false, on: plain)
                plain = settingFontSize(.standard, on: plain)
                attributedString.addAttribute(.font, value: plain, range: subrange)
            }
            attributedString.removeAttribute(.underlineStyle, range: range)
            attributedString.removeAttribute(.strikethroughStyle, range: range)
            // Task #178: explicit sentinels, not `removeAttribute` — same
            // reasoning as `applyTextColor(_:to:range:)`/
            // `applyBackgroundColor(_:to:range:)`.
            attributedString.addAttribute(.foregroundColor, value: defaultTextColor, range: range)
            attributedString.addAttribute(.backgroundColor, value: defaultBackgroundColor, range: range)
            attributedString.removeAttribute(.link, range: range)
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

    /// Task #161: dedicated 引用ブロック toggle, distinct from the numeric
    /// `applyIndent(by:)` stepper above even though both ultimately drive
    /// the same `indentLevel` storage (`RichTextHTMLCoder`'s doc comment on
    /// why `indentLevel` already renders as nested `<blockquote>`) — this
    /// one is a single on/off toggle (all touched paragraphs go to
    /// `indentLevel` 0 if every one of them is already quoted, or to 1
    /// otherwise), the same "not-yet-uniform → apply, already-uniform →
    /// remove" convention `applyList(_:to:range:)` uses, rather than
    /// incrementing/decrementing by one level per tap.
    static func applyBlockquote(to attributedString: NSMutableAttributedString, range: NSRange) {
        guard attributedString.length > 0 else { return }
        let paragraphRanges = paragraphRanges(coveringSelection: range, in: attributedString)
        guard !paragraphRanges.isEmpty else { return }
        let allAlreadyQuoted = paragraphRanges.allSatisfy { paragraphRange in
            paragraphListStyleAndIndent(at: paragraphRange.location, in: attributedString).1 > 0
        }
        let newLevel = allAlreadyQuoted ? 0 : 1
        for paragraphRange in paragraphRanges {
            let listStyle = paragraphListStyleAndIndent(at: paragraphRange.location, in: attributedString).0
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
