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
    ///
    /// No longer used by the top-level message list rows since the card
    /// layout replaced it (see `otegamiCardBorder()`) — kept as a general
    /// utility for any future plain (non-card) row list.
    func otegamiRowDivider() -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(OtegamiColor.dividerSubtle)
                .frame(height: OtegamiStroke.secondary)
                .accessibilityHidden(true)
        }
    }

    /// 表示・操作改善バッチ: the card-style list row border — a full 2pt
    /// `OtegamiColor.divider` frame around the row, replacing the previous
    /// "罫線で繋がったリスト" look (background color + a dashed line only
    /// between rows) with distinct, separated "面" per row. `OtegamiRadius
    /// .none` means this stays a plain rectangle, not a rounded card — the
    /// separation reads through spacing (the `List` row's own vertical
    /// inset, applied by the call site) and this border, in keeping with
    /// the design system's flat/angular Modernist base rather than
    /// introducing rounded corners.
    func otegamiCardBorder() -> some View {
        overlay {
            Rectangle()
                .strokeBorder(OtegamiColor.divider, lineWidth: OtegamiStroke.primary)
        }
    }
}
