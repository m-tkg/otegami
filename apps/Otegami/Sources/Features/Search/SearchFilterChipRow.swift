import SwiftUI

/// 1j's filter chip row — reuses `AccountFilterChip` (1a's chip component):
/// same flat, square-cornered toggle-button styling, just a different
/// selection model (one filter active at a time, not multi-select) and
/// values (`SearchFilterOption`, not accounts).
struct SearchFilterChipRow: View {
    @Binding var selection: SearchFilterOption

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OtegamiSpacing.sm) {
                ForEach(SearchFilterOption.allCases) { option in
                    AccountFilterChip(title: option.title, isSelected: selection == option) {
                        selection = option
                    }
                    .accessibilityIdentifier("search.filterChip.\(option.rawValue)")
                }
            }
            .padding(.horizontal, OtegamiSpacing.md)
            .padding(.vertical, OtegamiSpacing.xs)
        }
        .background(OtegamiColor.background)
        .accessibilityIdentifier("search.filterChipRow")
    }
}
