import CoreGraphics

/// Spacing scale — multiples of the handoff's 12pt base unit
/// (design_handoff_ios_mail/README.md's "Design Tokens" table: "余白 12px
/// を基本単位（行 padding 11–13px）"). Named by size (`xs`…`xl`), not by
/// where they're used, since the same value gets reused across unrelated
/// components (a chip's internal padding and a section's outer margin can
/// both legitimately want `.sm`).
public enum OtegamiSpacing {
    /// 4pt — tight internal padding (e.g. inside a small badge).
    public static let xs: CGFloat = 4
    /// 8pt — internal padding for compact controls (chips, badges).
    public static let sm: CGFloat = 8
    /// 12pt — the base unit itself; default row/section padding.
    public static let md: CGFloat = 12
    /// 16pt — spacing between distinct groups of content.
    public static let lg: CGFloat = 16
    /// 24pt — spacing between major sections.
    public static let xl: CGFloat = 24
    /// 32pt — largest gaps (e.g. above/below a full-bleed section break).
    public static let xxl: CGFloat = 32
}
