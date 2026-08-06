import SwiftUI

/// 実機フィードバック「mac 版において、グループ表示のときも検索バーを
/// 出して欲しい」対応。`AccountDigestView`(アカウント別グループ表示)は
/// 複数アカウント横断の集計画面で検索対象の`List`を持たないため、
/// `MacListSearchBar`をそのまま流用せず、1文字でも入力された瞬間に
/// `RootView`側で`isGroupByAccount`を`false`へ戻し時系列表示へ切り替える
/// 入口だけを持つ軽量版(`RootView.contentColumn`の`.onChange(of:
/// groupSearchText)`参照)。切替後は`MessageListView`側の本物の検索欄
/// (`MacListSearchBar`)で改めて検索する — スコープ切替/未読のみ/更新ボタン
/// はこのバーには持たせない(グループ表示中は対象がアカウント横断で
/// スコープの概念が無いため)。
///
/// 切替のトリガー自体はフォーカス (`FocusState`) の変化ではなくテキスト
/// 変更にしている — `FocusState`の変更通知だけを切替条件にすると実機で
/// 確実に効かないパターンが検証で見つかったため。`.focused(isFieldFocused)`
/// 自体は外せない — 無いとこの`TextField`がクリックでカーソル表示までは
/// されても実際のキー入力を受け付けない (同じ検証で確認済み)。
struct AccountDigestSearchBar: View {
    @Binding var searchText: String
    var isFieldFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(OtegamiColor.inkTertiary)
            TextField("検索", text: $searchText)
                .textFieldStyle(.plain)
                .font(OtegamiFont.body())
                .foregroundStyle(OtegamiColor.ink)
                .focused(isFieldFocused)
                .accessibilityIdentifier("accountDigest.search.field")
        }
        .padding(.horizontal, OtegamiSpacing.sm)
        .padding(.vertical, OtegamiSpacing.xs)
        // 2026-08-07 (メイン UI の macOS ネイティブ化): `MacListSearchBar`
        // と同じく、カプセル+`surface`塗りをやめ NSSearchField に近い
        // 控えめな角丸 + システム階層素材へ。
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, OtegamiSpacing.md)
        .padding(.vertical, OtegamiSpacing.sm)
    }
}
