import SwiftUI
import OtegamiCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

#if os(iOS)
typealias PlatformTextView = UITextView
#else
typealias PlatformTextView = NSTextView
#endif

/// Task #129 (作成画面リッチテキスト化): what `RichTextFormattingBar`'s buttons
/// call into. Created once by `ComposerView` (`@State`, survives across
/// `body` re-evaluations) and handed to both `RichTextEditor` (which wires
/// its `Coordinator` in as the actual `target` once the real
/// `UITextView`/`NSTextView` exists) and the formatting bar itself, so the
/// bar can drive the live text view without either side needing a direct
/// reference to the other.
@MainActor
final class RichTextEditingController: ObservableObject {
    /// What the formatting bar highlights as "currently active" — kept in
    /// sync by `Coordinator` on every edit/selection change.
    @Published fileprivate(set) var typingState = RichTextTypingState()

    fileprivate weak var target: RichTextEditingTarget?

    func toggleBold() { target?.toggleBold() }
    func toggleItalic() { target?.toggleItalic() }
    func toggleUnderline() { target?.toggleUnderline() }
    func toggleStrikethrough() { target?.toggleStrikethrough() }
    func toggleList(_ style: RichTextListStyle) { target?.toggleList(style) }
    func indent() { target?.changeIndent(by: 1) }
    func outdent() { target?.changeIndent(by: -1) }
    /// Task #161 (#129 第2段): 引用ブロック — see `RichTextAttributedString
    /// .applyBlockquote(to:range:)`'s doc comment for why this is its own
    /// toggle, not just another call to `indent()`.
    func toggleBlockquote() { target?.toggleBlockquote() }
    func setFontSize(_ size: RichTextFontSize) { target?.setFontSize(size) }
    func setTextColor(_ color: RichTextColor?) { target?.setTextColor(color) }
    func setBackgroundColor(_ color: RichTextColor?) { target?.setBackgroundColor(color) }
    /// `urlString == nil` removes the link — see `RichTextAttributedString
    /// .applyLink(_:to:range:)`'s doc comment.
    func setLink(_ urlString: String?) { target?.setLink(urlString) }
    func clearFormatting() { target?.clearFormatting() }
}

@MainActor
protocol RichTextEditingTarget: AnyObject {
    func toggleBold()
    func toggleItalic()
    func toggleUnderline()
    func toggleStrikethrough()
    func toggleList(_ style: RichTextListStyle)
    func changeIndent(by delta: Int)
    func toggleBlockquote()
    func setFontSize(_ size: RichTextFontSize)
    func setTextColor(_ color: RichTextColor?)
    func setBackgroundColor(_ color: RichTextColor?)
    func setLink(_ urlString: String?)
    func clearFormatting()
}

/// Task #129 (作成画面リッチテキスト化): `ComposerView`'s body editor —
/// replaces the M1-era SwiftUI `TextEditor(text:selection:)` with a real
/// `UITextView`/`NSTextView` bound to `NSAttributedString`, so formatting
/// (bold/italic/underline/strikethrough/lists/indent) can actually be
/// applied and rendered while composing, then serialized to HTML at send
/// time (`RichTextAttributedString.makeDocument(from:)` +
/// `RichTextHTMLCoder.encode(_:)`). The accessibility identifier stays
/// exactly what it was (`app.textViews["composer.body"]`, still a
/// `UITextView` under the hood) — every existing UITest that types into it
/// keeps working unchanged.
struct RichTextEditor {
    @Binding var attributedText: NSAttributedString
    @Binding var selectedRange: NSRange
    let controller: RichTextEditingController
    let accessibilityIdentifier: String
}

#if os(iOS)
extension RichTextEditor: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isScrollEnabled = true
        textView.backgroundColor = .clear
        textView.font = RichTextAttributedString.bodyFont
        textView.delegate = context.coordinator
        textView.accessibilityIdentifier = accessibilityIdentifier
        textView.textStorage.setAttributedString(attributedText)
        context.coordinator.attach(textView: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        guard !context.coordinator.isPushingLocalChange else { return }
        if textView.attributedText != attributedText {
            textView.textStorage.setAttributedString(attributedText)
        }
        if textView.selectedRange != selectedRange, selectedRange.location != NSNotFound {
            let length = (textView.text as NSString).length
            let clamped = NSRange(
                location: min(selectedRange.location, length),
                length: min(selectedRange.length, max(0, length - min(selectedRange.location, length)))
            )
            textView.selectedRange = clamped
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
}
#else
extension RichTextEditor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = true
        textView.font = RichTextAttributedString.bodyFont
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.textStorage?.setAttributedString(attributedText)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        context.coordinator.attach(textView: textView)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        textView.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        textView.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        guard !context.coordinator.isPushingLocalChange else { return }
        if textView.textStorage.map({ NSAttributedString(attributedString: $0) }) != attributedText {
            textView.textStorage?.setAttributedString(attributedText)
        }
        if textView.selectedRange != selectedRange, selectedRange.location != NSNotFound {
            let length = textView.string.utf16.count
            let clamped = NSRange(
                location: min(selectedRange.location, length),
                length: min(selectedRange.length, max(0, length - min(selectedRange.location, length)))
            )
            textView.selectedRange = clamped
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
}
#endif

extension RichTextEditor {
    @MainActor
    final class Coordinator: NSObject, RichTextEditingTarget {
        var parent: RichTextEditor
        fileprivate weak var textView: PlatformTextView?
        /// Set while this coordinator itself is the source of a change
        /// (a formatting command, or the delegate observing a keystroke) —
        /// `updateUIView`/`updateNSView` skip re-assigning the text view's
        /// content while this is `true`, which would otherwise reset the
        /// cursor position on every keystroke (SwiftUI re-invokes `update`
        /// right after the binding write below completes).
        fileprivate var isPushingLocalChange = false

        init(parent: RichTextEditor) {
            self.parent = parent
        }

        func attach(textView: PlatformTextView) {
            self.textView = textView
            parent.controller.target = self
            refreshTypingState()
        }

        // MARK: - Content/selection sync

        private func commitChange() {
            guard let textView else { return }
            isPushingLocalChange = true
            parent.attributedText = currentAttributedText(textView)
            parent.selectedRange = textView.selectedRange
            isPushingLocalChange = false
            refreshTypingState()
        }

        fileprivate func refreshTypingState() {
            guard let textView else { return }
            parent.controller.typingState = RichTextAttributedString.typingState(
                in: currentAttributedText(textView), selectedRange: textView.selectedRange
            )
        }

        // MARK: - RichTextEditingTarget

        func toggleBold() {
            withSelection { textView, storage, range in
                if range.length > 0 {
                    let enable = !RichTextAttributedString.isBoldUniform(in: currentAttributedText(textView), range: range)
                    RichTextAttributedString.applyBold(enable, to: storage, range: range)
                } else {
                    setTypingAttribute(on: textView) { font in RichTextAttributedString.settingBold(!RichTextAttributedString.isBold(font), on: font) }
                }
            }
        }

        func toggleItalic() {
            withSelection { textView, storage, range in
                if range.length > 0 {
                    let enable = !RichTextAttributedString.isItalicUniform(in: currentAttributedText(textView), range: range)
                    RichTextAttributedString.applyItalic(enable, to: storage, range: range)
                } else {
                    setTypingAttribute(on: textView) { font in RichTextAttributedString.settingItalic(!RichTextAttributedString.isItalic(font), on: font) }
                }
            }
        }

        func toggleUnderline() {
            withSelection { textView, storage, range in
                if range.length > 0 {
                    let enable = !RichTextAttributedString.isUnderlineUniform(in: currentAttributedText(textView), range: range)
                    RichTextAttributedString.applyUnderline(enable, to: storage, range: range)
                } else {
                    var attrs = textView.typingAttributes
                    let enable = ((attrs[.underlineStyle] as? Int) ?? 0) == 0
                    attrs[.underlineStyle] = enable ? NSUnderlineStyle.single.rawValue : 0
                    textView.typingAttributes = attrs
                }
            }
        }

        func toggleStrikethrough() {
            withSelection { textView, storage, range in
                if range.length > 0 {
                    let enable = !RichTextAttributedString.isStrikethroughUniform(in: currentAttributedText(textView), range: range)
                    RichTextAttributedString.applyStrikethrough(enable, to: storage, range: range)
                } else {
                    var attrs = textView.typingAttributes
                    let enable = ((attrs[.strikethroughStyle] as? Int) ?? 0) == 0
                    attrs[.strikethroughStyle] = enable ? NSUnderlineStyle.single.rawValue : 0
                    textView.typingAttributes = attrs
                }
            }
        }

        func toggleList(_ style: RichTextListStyle) {
            withSelection { _, storage, range in
                RichTextAttributedString.applyList(style, to: storage, range: range)
            }
        }

        func changeIndent(by delta: Int) {
            withSelection { _, storage, range in
                RichTextAttributedString.applyIndent(by: delta, to: storage, range: range)
            }
        }

        func toggleBlockquote() {
            withSelection { _, storage, range in
                RichTextAttributedString.applyBlockquote(to: storage, range: range)
            }
        }

        func setFontSize(_ size: RichTextFontSize) {
            withSelection { textView, storage, range in
                if range.length > 0 {
                    RichTextAttributedString.applyFontSize(size, to: storage, range: range)
                } else {
                    setTypingAttribute(on: textView) { font in RichTextAttributedString.settingFontSize(size, on: font) }
                }
            }
        }

        func setTextColor(_ color: RichTextColor?) {
            withSelection { textView, storage, range in
                if range.length > 0 {
                    RichTextAttributedString.applyTextColor(color, to: storage, range: range)
                } else {
                    var attrs = textView.typingAttributes
                    if let color {
                        attrs[.foregroundColor] = color.platformColor
                    } else {
                        attrs.removeValue(forKey: .foregroundColor)
                    }
                    textView.typingAttributes = attrs
                }
            }
        }

        func setBackgroundColor(_ color: RichTextColor?) {
            withSelection { textView, storage, range in
                if range.length > 0 {
                    RichTextAttributedString.applyBackgroundColor(color, to: storage, range: range)
                } else {
                    var attrs = textView.typingAttributes
                    if let color {
                        attrs[.backgroundColor] = color.platformColor
                    } else {
                        attrs.removeValue(forKey: .backgroundColor)
                    }
                    textView.typingAttributes = attrs
                }
            }
        }

        /// Task #161: unlike every other command here, a collapsed
        /// selection isn't simply "apply to future typing" — a link needs
        /// actual text to wrap. If the cursor sits inside an existing link
        /// (`existingLinkRange(in:at:)`), this edits/removes *that* run
        /// instead; otherwise a collapsed selection is a no-op (the
        /// formatting bar only enables its link button when there's a
        /// non-empty selection or the cursor is already inside a link —
        /// see `RichTextFormattingBar`'s doc comment).
        func setLink(_ urlString: String?) {
            withSelection { _, storage, range in
                if range.length > 0 {
                    RichTextAttributedString.applyLink(urlString, to: storage, range: range)
                } else if let existingRange = RichTextAttributedString.existingLinkRange(in: storage, at: range.location) {
                    RichTextAttributedString.applyLink(urlString, to: storage, range: existingRange)
                }
            }
        }

        func clearFormatting() {
            withSelection { textView, storage, range in
                RichTextAttributedString.clearFormatting(to: storage, range: range)
                if range.length == 0 {
                    var attrs = textView.typingAttributes
                    if let font = attrs[.font] as? PlatformFont {
                        var plain = RichTextAttributedString.settingItalic(false, on: RichTextAttributedString.settingBold(false, on: font))
                        plain = RichTextAttributedString.settingFontSize(.standard, on: plain)
                        attrs[.font] = plain
                    }
                    attrs.removeValue(forKey: .underlineStyle)
                    attrs.removeValue(forKey: .strikethroughStyle)
                    attrs.removeValue(forKey: .foregroundColor)
                    attrs.removeValue(forKey: .backgroundColor)
                    attrs.removeValue(forKey: .link)
                    textView.typingAttributes = attrs
                }
            }
        }

        private func setTypingAttribute(on textView: PlatformTextView, transform: (PlatformFont) -> PlatformFont) {
            var attrs = textView.typingAttributes
            let font = (attrs[.font] as? PlatformFont) ?? RichTextAttributedString.bodyFont
            attrs[.font] = transform(font)
            textView.typingAttributes = attrs
        }

        private func withSelection(_ body: (PlatformTextView, NSMutableAttributedString, NSRange) -> Void) {
            guard let textView, let storage = mutableStorage(of: textView) else { return }
            body(textView, storage, textView.selectedRange)
            commitChange()
        }
    }
}

// MARK: - Platform content accessors

private func currentAttributedText(_ textView: PlatformTextView) -> NSAttributedString {
    #if os(iOS)
    NSAttributedString(attributedString: textView.attributedText ?? NSAttributedString())
    #else
    NSAttributedString(attributedString: textView.textStorage ?? NSTextStorage())
    #endif
}

private func mutableStorage(of textView: PlatformTextView) -> NSMutableAttributedString? {
    #if os(iOS)
    textView.textStorage
    #else
    textView.textStorage
    #endif
}

#if os(iOS)
extension RichTextEditor.Coordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        commitChange()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        refreshTypingState()
    }
}
#else
extension RichTextEditor.Coordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        commitChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        refreshTypingState()
    }
}
#endif
