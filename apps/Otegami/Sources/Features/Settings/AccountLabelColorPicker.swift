import SwiftUI

/// D「アカウントのラベル色を変更可能に」: a row of tappable swatches (the eight
/// `OtegamiAccountColor.PaletteColor` entries) plus a leading "自動" (auto)
/// option, used by `AccountEditView`. Selection state (`nil` == 自動) lives
/// in the caller — this view is purely presentational, matching the rest of
/// this app's row-shaped `View`s (`ThreadRowView`/`MessageListRow`, per
/// `docs/ci.md`'s "keep row-shaped views small, and keep the loop body
/// itself down to one function call" discipline, applied here even though
/// this row has no `List`/`ForEach` of its own to worry about — a `HStack`
/// of eight circles plus a "自動" pill is still worth its own file/type
/// rather than inlining into `AccountEditView.body`).
struct AccountLabelColorPicker: View {
    @Binding var selection: OtegamiAccountColor.PaletteColor?
    /// The color "自動" would currently resolve to (the FNV-1a assignment
    /// for this account's id) — shown as the auto pill's own swatch so a
    /// user picking "自動" can see what they're getting, not just an empty
    /// placeholder.
    let autoColor: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OtegamiSpacing.sm) {
                autoSwatch
                ForEach(OtegamiAccountColor.PaletteColor.allCases, id: \.self) { paletteColor in
                    swatch(for: paletteColor)
                }
            }
            .padding(.vertical, OtegamiSpacing.xs)
        }
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
