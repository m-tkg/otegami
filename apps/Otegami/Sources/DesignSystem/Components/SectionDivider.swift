import SwiftUI

/// A full-bleed structural divider — 2pt solid, `OtegamiColor.divider` —
/// for separating major sections (e.g. the chip row from the message list
/// in 1a, or one settings block from the next in 1l). For the *lighter*
/// 1pt dashed rule the handoff uses between individual rows within a
/// section, apply `.otegamiRowDivider()` (also in this file) directly to
/// the row instead — a full `SectionDivider` view is too heavy-handed to
/// insert between every row in a `List`.
public struct SectionDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(OtegamiColor.divider)
            .frame(height: OtegamiStroke.primary)
            .accessibilityHidden(true)
    }
}

public extension View {
    /// The 1pt dashed row-level separator ("行間 1px dashed") as a bottom
    /// overlay, for use inside a `List`/`LazyVStack` row rather than as a
    /// separate divider view between rows.
    func otegamiRowDivider() -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(OtegamiColor.dividerSubtle)
                .frame(height: OtegamiStroke.secondary)
                .accessibilityHidden(true)
        }
    }
}
