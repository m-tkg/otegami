import SwiftUI

/// A9-1: a small, subdued badge marking a message as HTML (as opposed to
/// plain text) while its detail screen is showing the HTML rendering —
/// `MessageView` shows this next to the subject whenever `HTMLMessageView`
/// (not the plain-text/extracted-text path) is what's actually on screen.
/// Modeled directly on `ENBadge` (same tokens, same flat/square shape per
/// the design system's corner-radius-0 rule) rather than generalizing that
/// type, since both are small, independent, single-purpose labels with
/// their own fixed text and accessibility label — introducing a shared
/// parameterized "TextBadge" for just these two call sites would be more
/// indirection than the two flat `Text` badges it'd replace.
public struct HTMLBadge: View {
    public init() {}

    public var body: some View {
        Text("HTML")
            .font(OtegamiFont.badge())
            .foregroundStyle(OtegamiColor.inkSecondary)
            .padding(.horizontal, OtegamiSpacing.xs)
            .padding(.vertical, 2)
            .background(OtegamiColor.paleBase)
            .clipShape(Rectangle())
            .accessibilityIdentifier("messageDetail.htmlBadge")
            .accessibilityLabel("HTMLメール")
    }
}
