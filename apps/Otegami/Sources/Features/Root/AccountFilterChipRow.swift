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
///
/// Task #106: 先頭チップは「全部」→**「すべて」に改名**し、単純な選択解除
/// ボタンから「時系列 / アカウント別」を選ぶプルダウン (`AllModeFilterChip`,
/// SwiftUI `Menu`) に変わった — `MailScreenView`のヘッダにあった「アカウント
/// でグループ化」トグルボタン (Task #77/#92/#99) はこのチップに統合され廃止。
/// 永続化は同じ`ListDisplaySettingsStore.groupByAccountKey`をそのまま使う
/// (この行と`MailScreenView`はどちらも同じキーへの別々の`@AppStorage`
/// — `isUnreadOnly`と同じ「片方の変更がもう一方に伝わる」設計)。
struct AccountFilterChipRow: View {
    let accounts: [AccountRecord]
    @Binding var selectedAccountId: String?
    /// Task #181 (macOS サイドバーにも同じチップ行を追加): macOS はアカウント
    /// 別「ダイジェスト」表示 (`AccountDigestView`) を実装しない判断をした
    /// (macOS はサイドバーで既にアカウント別に辿れるため、iOS ほど価値が
    /// 高くない — `docs/design-system.md`のTask #181節参照)。そのため
    /// macOS では「すべて」チップに「時系列/アカウント別」を選ぶプルダウン
    /// (`AllModeFilterChip`) 自体を出さず、単純な絞り込み解除チップにする。
    /// デフォルト`true`(既存 iOS 呼び出し元の挙動は無変更)。
    var showsModePicker: Bool = true
    @AppStorage(ListDisplaySettingsStore.groupByAccountKey) private var isGroupByAccount = ListDisplaySettingsStore.defaultGroupByAccount

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OtegamiSpacing.sm) {
                // アカウントが1つしかない場合はダイジェスト表示に意味が
                // 無いため、「すべて」チップ自体を出さない (仕様通り) —
                // 個別アカウントチップは1件だけになるが、それ自体は今回の
                // 変更対象ではないのでそのまま残す。
                if accounts.count > 1 {
                    if showsModePicker {
                        AllModeFilterChip(isSelected: selectedAccountId == nil, isGroupByAccount: $isGroupByAccount, onSelectMode: selectAll)
                    } else {
                        // macOS: プルダウンで切り替えるモード自体が無いので、
                        // 「すべて」は他のチップと同じ`AccountFilterChip`の
                        // ただの絞り込み解除ボタン。「すべて」は動的データ
                        // ではない固定ラベルなので`isTitleLocalizable: true`
                        // (`AccountFilterChip.label`のdoc comment参照)。
                        AccountFilterChip(title: "すべて", isSelected: selectedAccountId == nil, isTitleLocalizable: true, action: selectAll)
                            .accessibilityIdentifier("mail.chip.all")
                    }
                }
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

/// Task #106: 「すべて」チップのプルダウン本体 — 見た目は`AccountFilterChip
/// .label`と同じ「塗り＋枠線」のフラットチップ (トークンを直接複製している
/// のは、`AccountFilterChip`の`label`が`private`でMenuのラベルとして再利用
/// できないため。デザイントークンはすべて既存のものを再利用しており新しい
/// 色は足していない — `CLAUDE.md`)。タップで開くメニューは「時系列」
/// (`isGroupByAccount = false`) / 「アカウント別」(`isGroupByAccount = true`)
/// の2択のみ — どちらを選んでも`onSelectMode`(=`selectedAccountId = nil`)
/// を呼び、個別アカウント絞り込み中であっても「すべて」に戻る (仕様「絞り
/// 込み解除でモードに応じた表示へ」)。
private struct AllModeFilterChip: View {
    let isSelected: Bool
    @Binding var isGroupByAccount: Bool
    let onSelectMode: () -> Void

    var body: some View {
        // Task #106 実機フィードバック: プルダウンは「すべて」が**既に選択
        // されている状態**でのみ開く。個別アカウント絞り込み中にタップした
        // 場合は、メニューを挟まず即「すべて」(保存済みモードのまま) へ
        // 戻る — 絞り込み解除のワンタップ動線にメニューが割り込むと邪魔、
        // という指摘への対応。
        Group {
            if isSelected {
                Menu {
                    Button {
                        selectMode(groupByAccount: false)
                    } label: {
                        Label("時系列", systemImage: "clock")
                    }
                    Button {
                        selectMode(groupByAccount: true)
                    } label: {
                        Label("アカウント別", systemImage: "person.2")
                    }
                } label: {
                    label
                }
            } else {
                Button(action: onSelectMode) {
                    label
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("mail.chip.all")
    }

    private func selectMode(groupByAccount: Bool) {
        isGroupByAccount = groupByAccount
        onSelectMode()
    }

    private var label: some View {
        // 固定ラベル同士の連結 (アカウント表示名のような動的な値は含まない)
        // だが、`Text(LocalizedStringKey:)`のMarkdown解釈を確実に避ける
        // ため`AccountFilterChip`の教訓 (`Text(verbatim:)`) に倣う。
        HStack(spacing: OtegamiSpacing.xs) {
            Text(verbatim: "\(String(localized: "すべて")) ▸ \(modeTitle)")
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .font(OtegamiFont.caption())
        .foregroundStyle(isSelected ? OtegamiColor.accentText : OtegamiColor.inkSecondary)
        .padding(.horizontal, OtegamiSpacing.md)
        .padding(.vertical, OtegamiSpacing.xs)
        .background(isSelected ? OtegamiColor.paleBaseStrong : OtegamiColor.surface)
        .overlay(
            Rectangle().strokeBorder(
                isSelected ? OtegamiColor.accent : OtegamiColor.dividerSubtle,
                lineWidth: OtegamiStroke.secondary
            )
        )
        .otegamiMinimumTappable()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var modeTitle: String {
        isGroupByAccount ? String(localized: "アカウント別") : String(localized: "時系列")
    }
}
