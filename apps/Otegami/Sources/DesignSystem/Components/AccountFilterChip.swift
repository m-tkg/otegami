import SwiftUI

/// The horizontal-scroll account/mailbox filter chip from 1a ("横スクロー
/// ルのチップ列（全部 / 仕事 / 個人 / ＋）"). A flat, square-cornered
/// toggle button — selected state reads via a filled pale-blue background
/// plus an accent-colored border, not via color alone (so it still reads
/// correctly for color-blind users and in the catalog's grayscale-ish
/// dark-mode swatches).
public struct AccountFilterChip: View {
    private let title: String
    private let isSelected: Bool
    private let action: () -> Void

    public init(title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(.plain)
        .otegamiMinimumTappable()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var label: some View {
        Text(title)
            .font(OtegamiFont.caption())
            .foregroundStyle(isSelected ? OtegamiColor.accentText : OtegamiColor.inkSecondary)
            .padding(.horizontal, OtegamiSpacing.md)
            .padding(.vertical, OtegamiSpacing.xs)
            .background(isSelected ? OtegamiColor.paleBaseStrong : OtegamiColor.surface)
            .overlay(border)
    }

    private var border: some View {
        Rectangle()
            .strokeBorder(
                isSelected ? OtegamiColor.accent : OtegamiColor.dividerSubtle,
                lineWidth: OtegamiStroke.secondary
            )
    }
}
