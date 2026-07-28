#if DEBUG
import SwiftUI

/// Task #72: two demonstrations of `OtegamiAccountColor` — every named
/// `PaletteColor` swatch (so the full 20-hue wheel is visible at a glance,
/// in the same hue order `AccountLabelColorPicker`'s grid uses), plus a
/// handful of sample account ids run through the FNV-1a hash fallback
/// (confirming the same id always maps to the same color).
struct CatalogAccountColorSection: View {
    private let sampleAccountIds = [
        "work@example.com", "personal@example.com", "team@example.com",
        "news@example.com", "school@example.com", "family@example.com",
        "shop@example.com", "backup@example.com",
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: OtegamiSpacing.sm), count: 8)

    var body: some View {
        CatalogSection(title: "Account colors — OtegamiAccountColor") {
            LazyVGrid(columns: columns, spacing: OtegamiSpacing.sm) {
                ForEach(OtegamiAccountColor.PaletteColor.allCases, id: \.self) { paletteColor in
                    Circle()
                        .fill(paletteColor.color)
                        .frame(width: 24, height: 24)
                }
            }

            SectionDivider()

            ForEach(sampleAccountIds, id: \.self) { accountId in
                CatalogAccountColorRow(accountId: accountId)
            }
        }
    }
}

private struct CatalogAccountColorRow: View {
    let accountId: String

    var body: some View {
        HStack(spacing: OtegamiSpacing.md) {
            AccountColorRail(accountId: accountId)
                .frame(height: 20)
            Text(accountId)
                .font(OtegamiFont.subheadline())
                .foregroundStyle(OtegamiColor.ink)
            Spacer()
        }
    }
}
#endif
