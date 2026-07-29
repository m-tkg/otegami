import SwiftUI

/// D「アカウントのラベル色を変更可能に」/ Task #72: a grid of tappable
/// swatches (all `OtegamiAccountColor.PaletteColor` entries, in hue order),
/// used by `AccountEditView`. Selection state lives in the caller — this
/// view is purely presentational, matching the rest of this app's
/// row-shaped `View`s (`ThreadRowView`/`MessageListRow`, per `docs/ci.md`'s
/// "keep row-shaped views small" discipline, applied here to the grid's
/// per-swatch cell).
///
/// 実機フィードバック (2026-07-29「自動、はいらない」): the leading "自動"
/// pill (`nil` selection, resolving to the FNV-1a hash assignment) was
/// removed — the grid is now exactly the 20 reference swatches. A `nil`
/// selection can still *arrive* here (legacy accounts saved before every
/// creation path started assigning an explicit color); it just renders as
/// no swatch selected until the user picks one.
///
/// Task #72 switched this from a single horizontally-scrolling `HStack` row
/// to a `LazyVGrid` — with the palette grown from 8 to 20 colors, a single
/// row would scroll far enough that most swatches were never visible without
/// deliberately dragging, which defeats "見て選ぶ" comparison shopping. A
/// 5-column grid (matching the reference screenshot's layout) keeps every
/// swatch on screen at once at the same 28pt size the old row used.
struct AccountLabelColorPicker: View {
    @Binding var selection: OtegamiAccountColor.PaletteColor?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: OtegamiSpacing.sm), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: OtegamiSpacing.sm) {
            ForEach(OtegamiAccountColor.PaletteColor.allCases, id: \.self) { paletteColor in
                swatch(for: paletteColor)
            }
        }
        .padding(.vertical, OtegamiSpacing.xs)
        .accessibilityIdentifier("accountEdit.labelColorPicker")
    }

    @ViewBuilder
    private func swatch(for paletteColor: OtegamiAccountColor.PaletteColor) -> some View {
        let isSelected = selection == paletteColor
        // Task #157: `.rose` now resolves to plain white (the reference
        // picker's grid-bottom-right swatch), which would otherwise
        // disappear against this view's own light-mode background — every
        // other swatch stays exactly as before (a hairline is only drawn
        // here, not universally, since a colored swatch already reads
        // fine against either background).
        let isWhiteSwatch = paletteColor == .rose
        Button {
            selection = paletteColor
        } label: {
            Circle()
                .fill(paletteColor.color)
                .frame(width: 28, height: 28)
                .overlay {
                    if isWhiteSwatch {
                        Circle().strokeBorder(OtegamiColor.divider, lineWidth: OtegamiStroke.secondary)
                    }
                }
                .overlay {
                    Circle().strokeBorder(OtegamiColor.ink, lineWidth: isSelected ? 2 : 0)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("accountEdit.labelColor.\(paletteColor.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
