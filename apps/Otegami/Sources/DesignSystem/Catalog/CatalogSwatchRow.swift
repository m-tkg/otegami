#if DEBUG
import SwiftUI

/// One labeled color swatch row, reused by every color-token section in
/// `DesignSystemCatalogView`. Kept as its own tiny `View` (per
/// `docs/ci.md`'s SwiftUI type-check guidance) rather than inlined in a
/// `ForEach` closure.
struct CatalogSwatchRow: View {
    let name: String
    let color: Color

    var body: some View {
        HStack(spacing: OtegamiSpacing.md) {
            Rectangle()
                .fill(color)
                .frame(width: 32, height: 32)
                .overlay(Rectangle().strokeBorder(OtegamiColor.dividerSubtle, lineWidth: OtegamiStroke.secondary))
            Text(name)
                .font(OtegamiFont.subheadline())
                .foregroundStyle(OtegamiColor.ink)
            Spacer()
        }
    }
}
#endif
