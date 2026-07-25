#if DEBUG
import SwiftUI

/// Every `OtegamiSpacing` step, as a labeled bar whose width equals the
/// token's value — a quick visual ruler.
struct CatalogSpacingSection: View {
    private let tokens: [(String, CGFloat)] = [
        ("xs (4)", OtegamiSpacing.xs),
        ("sm (8)", OtegamiSpacing.sm),
        ("md (12)", OtegamiSpacing.md),
        ("lg (16)", OtegamiSpacing.lg),
        ("xl (24)", OtegamiSpacing.xl),
        ("xxl (32)", OtegamiSpacing.xxl),
    ]

    var body: some View {
        CatalogSection(title: "Spacing — OtegamiSpacing") {
            ForEach(tokens, id: \.0) { token in
                CatalogSpacingRow(name: token.0, value: token.1)
            }
        }
    }
}

private struct CatalogSpacingRow: View {
    let name: String
    let value: CGFloat

    var body: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            Rectangle()
                .fill(OtegamiColor.accent)
                .frame(width: value, height: 12)
            Text(name)
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkSecondary)
        }
    }
}
#endif
