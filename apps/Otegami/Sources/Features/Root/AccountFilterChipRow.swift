import SwiftUI
import OtegamiStore

/// 1a's "横スクロールのチップ列（全部 / 仕事 / 個人）" — the handoff's original
/// design bundled a trailing "＋" (add account) chip into this row, but that
/// was removed (実機フィードバック): アカウント追加は設定画面
/// (「アカウントの設定」→「アカウントを追加」) から常にでき、ハンバーガー
/// メニュー側の同等ボタンも既に削除済み (`FolderListSheet`のドキュメント
/// コメント参照) — このチップ列だけに重複した入口を残す理由が無いと判断
/// した。アカウント0件時の空状態の「アカウントを追加」ボタン
/// (`MailScreenView.emptyState`) は引き続き独立した導線として残っている。
/// Horizontal-scroll, per the handoff's own documented risk:
/// "アカウントが5つ以上でチップが溢れる"; `ScrollView(.horizontal)` is
/// exactly the documented mitigation (`docs/design-system.md` records how
/// this was verified against a synthetic 6+ account list).
struct AccountFilterChipRow: View {
    let accounts: [AccountRecord]
    @Binding var selectedAccountId: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OtegamiSpacing.sm) {
                AccountFilterChip(title: "全部", isSelected: selectedAccountId == nil, action: selectAll)
                    .accessibilityIdentifier("mail.chip.all")
                ForEach(accounts) { account in
                    accountChip(for: account)
                }
            }
            .padding(.horizontal, OtegamiSpacing.md)
            .padding(.vertical, OtegamiSpacing.xs)
        }
        .background(OtegamiColor.background)
        .accessibilityIdentifier("mail.chipRow")
    }

    @ViewBuilder
    private func accountChip(for account: AccountRecord) -> some View {
        AccountFilterChip(title: account.displayName, isSelected: selectedAccountId == account.id, isTitleLocalizable: false) {
            select(account.id)
        }
        .accessibilityIdentifier("mail.chip.\(account.id)")
    }

    private func selectAll() {
        selectedAccountId = nil
    }

    private func select(_ accountId: String) {
        selectedAccountId = accountId
    }
}
