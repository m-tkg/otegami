import SwiftUI

/// 検索画面再構成 (Task #86, Sparkハンドオフ): 検索フィールド直下の「履歴」
/// 「保存済み」タブ — 選択中のタブだけアクセント下線を敷く、下線付きの
/// シンプルな2択。システムの`Picker(.segmented)`ではなく手書きにしたのは、
/// Sparkの参考画像がpill型セグメントではなく「文字+下線」のタブ表現
/// だったため。既存のフィルタチップ (`AccountFilterChip`) とはあえて
/// 見た目を変え、「これはフィルタではなくコンテンツの切り替えである」と
/// いう区別を保つ。
struct SearchTabRow: View {
    @Binding var selection: SearchTab

    var body: some View {
        HStack(spacing: OtegamiSpacing.lg) {
            ForEach(SearchTab.allCases) { tab in
                SearchTabButton(tab: tab, isSelected: selection == tab) {
                    selection = tab
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OtegamiSpacing.md)
        .padding(.top, OtegamiSpacing.sm)
        .accessibilityIdentifier("search.tabRow")
    }
}

/// `SearchTabRow`の`ForEach`の中身を独立した型に切り出したもの —
/// `docs/ci.md`のSwiftUI型チェックタイムアウト対策 (`CLAUDE.md`) と同じ
/// 理由: 1個のタブボタン (下線オーバーレイ込み) をインラインの`ForEach`の
/// 中に書くより、呼び出すだけの単純な型にする方が安全。
private struct SearchTabButton: View {
    let tab: SearchTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: OtegamiSpacing.xs) {
                Text(LocalizedStringKey(tab.title))
                    .font(OtegamiFont.subheadline())
                    .foregroundStyle(isSelected ? OtegamiColor.accentText : OtegamiColor.inkSecondary)
                Rectangle()
                    .fill(isSelected ? OtegamiColor.accent : Color.clear)
                    .frame(height: OtegamiStroke.primary)
            }
        }
        .buttonStyle(.plain)
        .otegamiMinimumTappable()
        .accessibilityIdentifier("search.tab.\(tab.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
