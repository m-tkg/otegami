#if DEBUG
import SwiftUI

/// Every `OtegamiFont` style, rendered with a mixed Japanese/English
/// sample string so the Archivo-for-Latin / system-font-for-Japanese
/// fallback (see `OtegamiFont`'s doc comment) is visible in one glance —
/// if Archivo failed to register, the Latin half of each sample would
/// visibly switch to the system font too.
struct CatalogTypographySection: View {
    private let sample = "Otegami お手紙 123"
    private let styles: [(String, Font)] = [
        ("largeTitle", OtegamiFont.largeTitle()),
        ("title", OtegamiFont.title()),
        ("headline", OtegamiFont.headline()),
        ("body", OtegamiFont.body()),
        ("subheadline", OtegamiFont.subheadline()),
        ("caption", OtegamiFont.caption()),
        ("badge", OtegamiFont.badge()),
    ]

    var body: some View {
        CatalogSection(title: "Typography — OtegamiFont") {
            ForEach(styles, id: \.0) { style in
                CatalogTypographyRow(name: style.0, font: style.1, sample: sample)
            }
        }
    }
}

private struct CatalogTypographyRow: View {
    let name: String
    let font: Font
    let sample: String

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs / 2) {
            Text(sample)
                .font(font)
                .foregroundStyle(OtegamiColor.ink)
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(OtegamiColor.inkTertiary)
        }
    }
}
#endif
