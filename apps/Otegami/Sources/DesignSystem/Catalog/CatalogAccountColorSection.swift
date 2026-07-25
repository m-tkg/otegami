#if DEBUG
import SwiftUI

/// Sample account ids run through `OtegamiAccountColor` — demonstrates
/// the full 8-color palette (there are exactly 8 sample ids below so
/// every palette slot appears at least once) and that the same id always
/// maps to the same color.
struct CatalogAccountColorSection: View {
    private let sampleAccountIds = [
        "work@example.com", "personal@example.com", "team@example.com",
        "news@example.com", "school@example.com", "family@example.com",
        "shop@example.com", "backup@example.com",
    ]

    var body: some View {
        CatalogSection(title: "Account colors — OtegamiAccountColor") {
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
