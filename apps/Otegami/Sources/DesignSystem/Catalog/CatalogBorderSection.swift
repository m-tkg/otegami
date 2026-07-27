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
                Text("radius: \(Int(OtegamiRadius.none))pt everywhere except cards")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                Text("card (\(Int(OtegamiRadius.card))pt, no border — 実機フィードバック第2弾 C)")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                RoundedRectangle(cornerRadius: OtegamiRadius.card, style: .continuous)
                    .fill(OtegamiColor.surface)
                    .frame(height: 28)
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
