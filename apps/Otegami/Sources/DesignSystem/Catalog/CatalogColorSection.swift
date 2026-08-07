#if DEBUG
import SwiftUI

/// Every `OtegamiColor` token, one swatch row each. Split out of
/// `DesignSystemCatalogView` (see that file's doc comment on why every
/// section here is its own `View` type).
struct CatalogColorSection: View {
    private let tokens: [(String, Color)] = [
        ("surface", OtegamiColor.surface),
        ("ink", OtegamiColor.ink),
        ("inkSecondary", OtegamiColor.inkSecondary),
        ("inkTertiary", OtegamiColor.inkTertiary),
        ("paleBase", OtegamiColor.paleBase),
        ("paleBaseStrong", OtegamiColor.paleBaseStrong),
        ("paleBaseStrongest", OtegamiColor.paleBaseStrongest),
        ("accent", OtegamiColor.accent),
        ("accentText", OtegamiColor.accentText),
        ("destructive", OtegamiColor.destructive),
        ("divider", OtegamiColor.divider),
        ("dividerSubtle", OtegamiColor.dividerSubtle),
    ]

    var body: some View {
        CatalogSection(title: "Colors — OtegamiColor") {
            ForEach(tokens, id: \.0) { token in
                CatalogSwatchRow(name: token.0, color: token.1)
            }
        }
    }
}
#endif
