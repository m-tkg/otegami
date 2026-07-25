#if DEBUG
import SwiftUI

/// The two stroke tokens (`OtegamiStroke.primary`/`.secondary`), shown
/// solid and dashed respectively to match how they're actually used
/// (`SectionDivider`/`.otegamiRowDivider()`).
struct CatalogBorderSection: View {
    var body: some View {
        CatalogSection(title: "Borders — OtegamiStroke / OtegamiRadius") {
            VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
                Text("primary (2pt solid)")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                Rectangle()
                    .fill(OtegamiColor.divider)
                    .frame(height: OtegamiStroke.primary)
                Text("secondary (1pt dashed)")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                dashedLine
                Text("radius: \(Int(OtegamiRadius.none))pt everywhere (flat, no rounded corners)")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
            }
        }
    }

    private var dashedLine: some View {
        Rectangle()
            .fill(OtegamiColor.dividerSubtle)
            .frame(height: OtegamiStroke.secondary)
    }
}
#endif
