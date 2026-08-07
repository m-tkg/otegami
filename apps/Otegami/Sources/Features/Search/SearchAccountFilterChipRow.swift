import SwiftUI
import OtegamiStore

/// 新画面構成 (2): 検索画面の「アカウントの絞り込み」チップ行。
/// `AccountFilterChipRow` (1a のメール一覧チップ行) とほぼ同じ見た目だが、
/// 検索画面には「＋アカウント追加」の導線は不要なので、独立した小さいコン
/// ポーネントにした (`AccountFilterChipRow` を条件分岐だらけにするより、この
/// 画面専用の単純な版を持つ方が読みやすいと判断)。
struct SearchAccountFilterChipRow: View {
    let accounts: [AccountRecord]
    @Binding var selectedAccountId: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OtegamiSpacing.sm) {
                AccountFilterChip(title: "全部", isSelected: selectedAccountId == nil) {
                    selectedAccountId = nil
                }
                .accessibilityIdentifier("search.accountChip.all")
                ForEach(accounts) { account in
                    AccountFilterChip(title: account.displayName, isSelected: selectedAccountId == account.id, isTitleLocalizable: false) {
                        selectedAccountId = account.id
                    }
                    .accessibilityIdentifier("search.accountChip.\(account.id)")
                }
            }
            .padding(.horizontal, OtegamiSpacing.md)
            .padding(.vertical, OtegamiSpacing.xs)
        }
        // Liquid Glass Phase 4: 独自`background`塗りを廃止 — 各チップは
        // `AccountFilterChip`経由で既に Glass 化済みなので、この行自体は
        // 標準の透明な背景に委ねる。
        .accessibilityIdentifier("search.accountChipRow")
    }
}
