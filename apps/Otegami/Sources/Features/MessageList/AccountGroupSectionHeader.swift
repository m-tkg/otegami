import SwiftUI

/// Task #77 (ユーザー要望「アカウントごとにグルーピングする設定」、Spark の
/// 参考画像参照): `MessageListView`の「アカウントでグループ化」トグル ON 時
/// の1セクション見出し — `AccountColorRail`（1d の3pxアカウント色罫線）＋
/// アカウント表示名＋件数バッジ。参考画像の「色バー＋アカウント名＋件数
/// (例: "Gmail 33")」を、この design system 既存のトークンで再現する。
///
/// 参考画像の差出人アバターのダイジェスト行 (セクション内のメール群を要約
/// する複数アバター) は第一弾スコープ外 — `docs/design-system.md`の
/// Task #77 節に記録済み。件数バッジは丸ピルではなく`ThreadRowTextStack`の
/// スレッド内メッセージ数バッジと同じ「角丸0＋`paleBase`背景」— `OtegamiRadius`
/// のdoc comment「バッジは角丸0のまま、丸めるのはカードだけ」という既存方針
/// に従う（Spark 側の丸ピルは意図的に採用しない）。
///
/// 独立した`View`型として`MessageListView.swift`から切り出す — `docs/ci.md`
/// の「1つの`View`のbodyを長く書かない／`ForEach`の中身は独立した`View`に
/// 切り出す」というCI型チェックタイムアウト対策の徹底方針にならう
/// (`MessageListRow`/`ThreadRowView`と同じ切り出し方)。
struct AccountGroupSectionHeader: View {
    let accountId: String
    /// `AccountFilterChip.label`/`FolderListSheet.CategoryAccountRow`と同じ
    /// 理由で`Text(verbatim:)`を使う — 表示名がメールアドレスそのもの
    /// (アカウント追加時に表示名を空にした場合の既定) だと、
    /// `LocalizedStringKey`経由ではSwiftUIがMarkdownの自動リンクとして
    /// 解釈し、タップで`mailto:`が開く実機バグを踏む(該当箇所のdoc comment
    /// 参照)。ここは静的な`Section`見出しでタップ自体は無いが、同じ文字列を
    /// 扱う以上は同じ経路の危険を避けておく。
    let accountDisplayName: String
    /// D「アカウントのラベル色を変更可能に」: `AccountRecord.labelColorKey`,
    /// forwarded to `AccountColorRail` as-is (`nil` = automatic FNV-1a
    /// assignment) — `ThreadRowView`/`CategoryAccountRow`と同じ使い方。
    let labelColorKey: String?
    /// このセクションに属する行数 — `MessageListView.groupedSummaries`の
    /// `AccountGroup.summaries.count`をそのまま渡す。
    let count: Int

    var body: some View {
        HStack(spacing: 0) {
            AccountColorRail(accountId: accountId, labelColorKey: labelColorKey)
            HStack(spacing: OtegamiSpacing.sm) {
                Text(verbatim: accountDisplayName)
                    .font(OtegamiFont.headline())
                    .foregroundStyle(OtegamiColor.ink)
                    .lineLimit(1)
                Text("\(count)")
                    .font(OtegamiFont.badge())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .padding(.horizontal, OtegamiSpacing.xs)
                    .padding(.vertical, 2)
                    .background(OtegamiColor.paleBase)
                    .accessibilityIdentifier("messageList.accountSection.\(accountId).countBadge")
                Spacer(minLength: 0)
            }
            .padding(.leading, OtegamiSpacing.sm)
            .padding(.vertical, OtegamiSpacing.xs)
        }
        // `Section`の既定ヘッダースタイル (システムの大文字変換・上寄せの
        // 余白) を、この行が`ThreadRowView`の行と地続きに見えるよう外す。
        .textCase(nil)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("messageList.accountSection.\(accountId).header")
    }
}
