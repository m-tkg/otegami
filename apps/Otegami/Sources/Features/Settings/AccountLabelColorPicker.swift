import SwiftUI

/// D「アカウントのラベル色を変更可能に」/ Task #72: a grid of tappable
/// swatches (all `OtegamiAccountColor.PaletteColor` entries, in hue order)
/// plus a leading "自動" (auto) option, used by `AccountEditView`. Selection
/// state (`nil` == 自動) lives in the caller — this view is purely
/// presentational, matching the rest of this app's row-shaped `View`s
/// (`ThreadRowView`/`MessageListRow`, per `docs/ci.md`'s "keep row-shaped
/// views small" discipline, applied here to the grid's per-swatch cell).
///
/// Task #72 switched this from a single horizontally-scrolling `HStack` row
/// to a `LazyVGrid` — with the palette grown from 8 to 20 colors, a single
/// row would scroll far enough that most swatches were never visible without
/// deliberately dragging, which defeats "見て選ぶ" comparison shopping. A
/// 5-column grid (matching the reference screenshot's layout) keeps every
/// swatch on screen at once at the same 28pt size the old row used.
struct AccountLabelColorPicker: View {
    @Binding var selection: OtegamiAccountColor.PaletteColor?
    /// The color "自動" would currently resolve to (the FNV-1a assignment
    /// for this account's id) — shown as the auto pill's own swatch so a
    /// user picking "自動" can see what they're getting, not just an empty
    /// placeholder.
    let autoColor: Color

    private let columns = Array(repeating: GridItem(.flexible(), spacing: OtegamiSpacing.sm), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: OtegamiSpacing.sm) {
            autoSwatch
            ForEach(OtegamiAccountColor.PaletteColor.allCases, id: \.self) { paletteColor in
                swatch(for: paletteColor)
            }
        }
        .padding(.vertical, OtegamiSpacing.xs)
        .accessibilityIdentifier("accountEdit.labelColorPicker")
    }

    private var autoSwatch: some View {
        Button {
            selection = nil
        } label: {
            VStack(spacing: OtegamiSpacing.xs) {
                Circle()
                    .fill(autoColor)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Circle().strokeBorder(OtegamiColor.ink, lineWidth: selection == nil ? 2 : 0)
                    }
                Text("自動")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("accountEdit.labelColor.auto")
        .accessibilityAddTraits(selection == nil ? .isSelected : [])
    }

    @ViewBuilder
    private func swatch(for paletteColor: OtegamiAccountColor.PaletteColor) -> some View {
        let isSelected = selection == paletteColor
        Button {
            selection = paletteColor
        } label: {
            Circle()
                .fill(paletteColor.color)
                .frame(width: 28, height: 28)
                .overlay {
                    Circle().strokeBorder(OtegamiColor.ink, lineWidth: isSelected ? 2 : 0)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("accountEdit.labelColor.\(paletteColor.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
