#if DEBUG
import SwiftUI

/// A titled block with a leading section divider — the catalog's own
/// layout scaffolding, reused by every section type below.
struct CatalogSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
            Text(title)
                .font(OtegamiFont.headline())
                .foregroundStyle(OtegamiColor.ink)
            SectionDivider()
            VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
                content
            }
        }
        .padding(.vertical, OtegamiSpacing.md)
    }
}
#endif
