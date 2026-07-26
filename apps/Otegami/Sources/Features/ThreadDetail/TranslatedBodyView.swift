import SwiftUI
import OtegamiStore

/// 1i's "段落長押しでその段落だけ原文表示" — renders a cached translation's
/// paragraphs (`MessageTranslationRecord.paragraphs`, index-aligned with the
/// original text `ParagraphSplitter.split(_:)` produced) as plain `Text`,
/// one per paragraph, each independently toggleable to its own original via
/// long-press. Only ever shown when the bar's segment is "訳文" — "原文" (or
/// no translation yet) falls back to `MessageView`'s normal body rendering
/// (`HTMLMessageView`/plain-text `Text`) untouched, so this view never needs
/// to duplicate link detection or HTML rendering itself.
///
/// design-phase-3 deviation: for an HTML-bodied message, "訳文" renders the
/// translated *plain text* (the engine only ever translates plain-text
/// paragraphs — `docs/translation.md` — never raw HTML), not a re-rendered
/// HTML document. Formatting (bold, links, layout) is lost in that case;
/// documented as an accepted tradeoff in `docs/design-system.md` rather than
/// building an HTML-preserving translation pipeline, which the underlying
/// `TranslationService` API doesn't support in the first place (it only
/// ever takes/returns plain strings).
struct TranslatedBodyView: View {
    let paragraphs: [TranslatedParagraph]
    /// Indices currently pinned to show their *original* text instead of
    /// the translation — toggled by long-pressing that one paragraph.
    /// Owned by the parent (`MessageView`) so it can reset alongside the
    /// rest of that view's translation state whenever `messageId` changes.
    @Binding var originalOverrides: Set<Int>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OtegamiSpacing.md) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    paragraphView(index: index, paragraph: paragraph)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .accessibilityIdentifier("messageDetail.translatedBody")
    }

    private func paragraphView(index: Int, paragraph: TranslatedParagraph) -> some View {
        let showingOriginal = originalOverrides.contains(index)
        return Text(showingOriginal ? paragraph.original : paragraph.translated)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(OtegamiSpacing.sm)
            .background(showingOriginal ? OtegamiColor.paleBaseStrong : Color.clear)
            .accessibilityIdentifier("messageDetail.translatedParagraph.\(index)")
            .onLongPressGesture(minimumDuration: 0.4) {
                toggleOriginal(index)
            }
    }

    private func toggleOriginal(_ index: Int) {
        if originalOverrides.contains(index) {
            originalOverrides.remove(index)
        } else {
            originalOverrides.insert(index)
        }
    }
}
