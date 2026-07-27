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
    /// Whether `title` should be looked up in the string catalog. Fixed
    /// labels ("全部"/"＋") want that; an account's display name must not
    /// take that path — see `label`'s doc comment for the real-device bug
    /// that forced this distinction.
    private let isTitleLocalizable: Bool
    private let action: () -> Void

    public init(title: String, isSelected: Bool, isTitleLocalizable: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.isTitleLocalizable = isTitleLocalizable
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
        // 固定ラベル (「全部」「＋」) だけを `LocalizedStringKey` 経由で
        // 引く。**アカウント表示名を同じ経路に流してはいけない**:
        // `LocalizedStringKey` は文字列を Markdown として解釈するため、
        // 表示名がメールアドレスそのもの (アカウント追加時に表示名を
        // 空にした場合の既定) だと SwiftUI が自動リンク化し、チップを
        // タップすると `mailto:` が開いてメール作成画面に飛ぶ、という
        // 実機バグが発生した (該当チップだけリンク色で描画されるのが
        // 目印だった)。動的テキストは `Text(verbatim:)` で素通しする。
        Group {
            if isTitleLocalizable {
                Text(LocalizedStringKey(title))
            } else {
                Text(verbatim: title)
            }
        }
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
