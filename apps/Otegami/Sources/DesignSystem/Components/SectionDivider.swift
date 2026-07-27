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
    /// layout replaced it (see `otegamiCardBackground(_:)`) — kept as a
    /// general utility for any future plain (non-card) row list.
    func otegamiRowDivider() -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(OtegamiColor.dividerSubtle)
                .frame(height: OtegamiStroke.secondary)
                .accessibilityHidden(true)
        }
    }

    /// 実機フィードバック第2弾 (C): the message-list row card — no outline
    /// (per the user's explicit instruction: "カードの輪郭線を描かない。背景色
    /// (surface) だけで面を表現"), just `color` filled into a rounded shape
    /// (`OtegamiRadius.card`) and clipped so every child — including
    /// `AccountColorRail`'s sharp-cornered rectangle at the row's leading
    /// edge — follows the same rounded silhouette rather than poking out
    /// past it. Replaces the previous `otegamiCardBorder()` (a 2pt
    /// `OtegamiColor.divider` stroke around a plain, unrounded rectangle) —
    /// separation between adjacent cards still reads through spacing alone
    /// (the `List` row's own vertical/horizontal inset, applied by the call
    /// site), same as before; only the fill shape and the removed stroke
    /// changed.
    func otegamiCardBackground(_ color: Color) -> some View {
        background(color)
            .clipShape(RoundedRectangle(cornerRadius: OtegamiRadius.card, style: .continuous))
    }
}
