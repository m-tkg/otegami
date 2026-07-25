import SwiftUI

/// Guarantees a view's tappable area is at least 44×44pt — the handoff's
/// hard rule ("タップ領域は 44pt 以上を厳守", repeated for every
/// interactive element in 1a/1g/1h/1i) — without changing how the view
/// *looks*. Expands the hit-testable frame via `.contentShape`, so a small
/// visual glyph (e.g. a 16pt selection checkbox in 1h) still gets a full
/// 44pt tap target centered on it, rather than forcing the glyph itself to
/// grow.
public extension View {
    /// - Parameter alignment: how the visual content sits within the
    ///   expanded 44×44 tap target, for cases where the glyph isn't
    ///   naturally centered in its layout slot (e.g. a leading-aligned
    ///   checkbox at the start of a row).
    func otegamiMinimumTappable(alignment: Alignment = .center) -> some View {
        modifier(MinimumTappableModifier(alignment: alignment))
    }
}

private struct MinimumTappableModifier: ViewModifier {
    static let minimumDimension: CGFloat = 44

    let alignment: Alignment

    func body(content: Content) -> some View {
        content
            .frame(
                minWidth: Self.minimumDimension,
                minHeight: Self.minimumDimension,
                alignment: alignment
            )
            .contentShape(Rectangle())
    }
}
