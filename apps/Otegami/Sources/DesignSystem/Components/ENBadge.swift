import SwiftUI

/// The "EN" badge used to flag English-language mail (1e's language-first
/// row treatment, and 1j's search filter chip) — a small filled label,
/// flat/square per the design system's corner-radius-0 rule.
public struct ENBadge: View {
    public init() {}

    public var body: some View {
        Text("EN")
            .font(OtegamiFont.badge())
            .foregroundStyle(OtegamiColor.accentText)
            .padding(.horizontal, OtegamiSpacing.xs)
            .padding(.vertical, 2)
            .background(OtegamiColor.paleBaseStrong)
            .clipShape(Rectangle())
            .accessibilityLabel("英語のメール")
    }
}
