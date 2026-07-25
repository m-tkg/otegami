import SwiftUI
import OtegamiStore

/// 1a's "横スクロールのチップ列（全部 / 仕事 / 個人 / ＋）" — the last chip is
/// "add account" (the handoff bundles that affordance directly into the
/// chip row rather than a separate toolbar button). Horizontal-scroll, per
/// the handoff's own documented risk: "アカウントが5つ以上でチップが溢れる";
/// `ScrollView(.horizontal)` is exactly the documented mitigation
/// (`docs/design-system.md` records how this was verified against a
/// synthetic 6+ account list).
struct AccountFilterChipRow: View {
    let accounts: [AccountRecord]
    @Binding var selectedAccountId: String?
    var onAddAccount: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OtegamiSpacing.sm) {
                AccountFilterChip(title: "全部", isSelected: selectedAccountId == nil, action: selectAll)
                    .accessibilityIdentifier("mail.chip.all")
                ForEach(accounts) { account in
                    accountChip(for: account)
                }
                AccountFilterChip(title: "＋", isSelected: false, action: onAddAccount)
                    .accessibilityIdentifier("mail.chip.addAccount")
            }
            .padding(.horizontal, OtegamiSpacing.md)
            .padding(.vertical, OtegamiSpacing.xs)
        }
        .background(OtegamiColor.background)
        .accessibilityIdentifier("mail.chipRow")
    }

    @ViewBuilder
    private func accountChip(for account: AccountRecord) -> some View {
        AccountFilterChip(title: account.displayName, isSelected: selectedAccountId == account.id) {
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
