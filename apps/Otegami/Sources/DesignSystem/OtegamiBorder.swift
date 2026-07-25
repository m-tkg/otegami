import CoreGraphics

/// Stroke widths and corner radii — the Modernist base system's flat,
/// angular styling (design_handoff_ios_mail/README.md: "フラット、角丸0、
/// 2px罫"). Every corner radius in this design system is `0` deliberately;
/// `OtegamiRadius.none` exists as a named token anyway (rather than call
/// sites writing a bare `0`) so a future revision to the corner-radius
/// language only has to change one place.
public enum OtegamiStroke {
    /// Primary structural dividers (section breaks, the account-color
    /// rail) — 2pt solid, paired with `OtegamiColor.divider`.
    public static let primary: CGFloat = 2
    /// Row-level separators inside a list — 1pt dashed, paired with
    /// `OtegamiColor.dividerSubtle`.
    public static let secondary: CGFloat = 1
}

public enum OtegamiRadius {
    /// Every corner in this design system. Flat, not rounded — see the
    /// type's doc comment.
    public static let none: CGFloat = 0
}
