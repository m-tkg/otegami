import SwiftUI
import OtegamiCore

/// Task #129 (作成画面リッチテキスト化): the formatting bar for
/// `ComposerView`'s body editor — 太字/イタリック/下線/打ち消し線/番号付き
/// リスト/箇条書きリスト/インデント増減/書式クリア, one icon button each.
/// Placed by `ComposerView.bodySection` directly above the body
/// `RichTextEditor` on both platforms — an inline SwiftUI toolbar (the
/// plan's other option alongside a keyboard `inputAccessoryView`) rather
/// than docked to the keyboard, so it's visible (and screenshot-testable
/// via `scripts/verify-screen.sh composer-richtext`) without first having
/// to focus the text view.
///
/// A single `@ViewBuilder` `body` with one `HStack` of independent
/// `FormatBarButton`s — deliberately not a `ForEach` over a config array —
/// keeps this well clear of the SwiftUI type-check-timeout pitfall
/// documented in `docs/ci.md` (`ComposerView`'s own "MARK: - Form sections"
/// doc comment has the fuller story); each button is its own small `View`
/// value already, so the `HStack` itself stays a flat, cheap-to-check list.
struct RichTextFormattingBar: View {
    @ObservedObject var controller: RichTextEditingController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OtegamiSpacing.xs) {
                FormatBarButton(systemImage: "bold", isActive: controller.typingState.isBold, accessibilityIdentifier: "composer.format.bold") {
                    controller.toggleBold()
                }
                FormatBarButton(systemImage: "italic", isActive: controller.typingState.isItalic, accessibilityIdentifier: "composer.format.italic") {
                    controller.toggleItalic()
                }
                FormatBarButton(systemImage: "underline", isActive: controller.typingState.isUnderline, accessibilityIdentifier: "composer.format.underline") {
                    controller.toggleUnderline()
                }
                FormatBarButton(systemImage: "strikethrough", isActive: controller.typingState.isStrikethrough, accessibilityIdentifier: "composer.format.strikethrough") {
                    controller.toggleStrikethrough()
                }
                Divider().frame(height: 20)
                FormatBarButton(systemImage: "list.bullet", isActive: controller.typingState.listStyle == .bullet, accessibilityIdentifier: "composer.format.bulletList") {
                    controller.toggleList(.bullet)
                }
                FormatBarButton(systemImage: "list.number", isActive: controller.typingState.listStyle == .ordered, accessibilityIdentifier: "composer.format.numberedList") {
                    controller.toggleList(.ordered)
                }
                FormatBarButton(systemImage: "decrease.indent", isActive: false, accessibilityIdentifier: "composer.format.outdent") {
                    controller.outdent()
                }
                FormatBarButton(systemImage: "increase.indent", isActive: false, accessibilityIdentifier: "composer.format.indent") {
                    controller.indent()
                }
                Divider().frame(height: 20)
                FormatBarButton(systemImage: "textformat.slash", isActive: false, accessibilityIdentifier: "composer.format.clear") {
                    controller.clearFormatting()
                }
            }
            .padding(.horizontal, OtegamiSpacing.sm)
            .padding(.vertical, OtegamiSpacing.xs)
        }
        .background(OtegamiColor.surface)
        .accessibilityIdentifier("composer.formattingBar")
    }
}

/// One formatting bar button — pulled out into its own `View` (not an
/// inline closure in the `HStack` above) for the same reason
/// `ComposerView`'s `AttachmentRow` is its own type: keeps the containing
/// container's body a flat list of cheap-to-check leaves.
private struct FormatBarButton: View {
    let systemImage: String
    let isActive: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 32)
                .foregroundStyle(isActive ? OtegamiColor.accentText : OtegamiColor.inkSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? OtegamiColor.paleBaseStrong : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
