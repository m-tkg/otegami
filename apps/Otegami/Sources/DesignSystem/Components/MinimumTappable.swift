import SwiftUI

/// The platform HIG's minimum tappable dimension (44×44pt) as a single
/// named constant, so every call site that needs "the 44pt rule" —
/// `otegamiMinimumTappable()` below, but also e.g. `List`'s
/// `defaultMinListRowHeight` environment value for a row-based menu
/// (`FolderListSheet`, Task #191) — references the same token instead of
/// re-typing a bare `44`.
public enum OtegamiTapTarget {
    public static let minimum: CGFloat = 44
}

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
    let alignment: Alignment

    func body(content: Content) -> some View {
        content
            .frame(
                minWidth: OtegamiTapTarget.minimum,
                minHeight: OtegamiTapTarget.minimum,
                alignment: alignment
            )
            .contentShape(Rectangle())
    }
}
