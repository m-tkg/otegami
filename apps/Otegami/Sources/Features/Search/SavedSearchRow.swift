import SwiftUI
import OtegamiStore

/// 検索画面再構成 (Task #86)「保存済み」タブの1行 — クエリ文字列 + (絞り込み
/// が「全部」でない、またはアカウント絞りがある場合だけ) その条件を示す
/// キャプション。タップで`SavedSearchRecord`が持つクエリ+フィルタ+アカウント
/// を一括で再適用する (`SearchScreenView.applySavedSearch(_:)`)。
///
/// `Label(entry.queryText, systemImage:)`にしなかった理由:
/// `Label(_:systemImage:)`の第1引数は`LocalizedStringKey`であり、
/// `AccountFilterChip.label`のドキュメントコメントが記録した実機バグ
/// (動的文字列がメールアドレスだと SwiftUI が Markdown 経由で自動的に
/// `mailto:` リンク化してしまう) と同じ経路を踏む — 保存されたクエリ
/// 文字列は「差出人アドレスそのもの」であることが十分あり得るため、ここも
/// `Text(verbatim:)`で素通しする。
struct SavedSearchRow: View {
    let entry: SavedSearchRecord
    /// `entry.accountId`が指すアカウントの表示名。`nil` (全部) の場合や、
    /// 該当アカウントが既に削除済みの場合は`nil`のまま渡す。
    let accountDisplayName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            HStack(spacing: OtegamiSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(OtegamiColor.inkSecondary)
                Text(verbatim: entry.queryText)
                    .font(OtegamiFont.body())
                    .foregroundStyle(OtegamiColor.ink)
                    .lineLimit(1)
            }
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
            }
        }
    }

    /// `nil`のときは「全部・全アカウント」のプレーンな保存で、追加で見せる
    /// ことが無い。
    private var subtitle: String? {
        let filterOption = SearchFilterOption.persisted(rawValue: entry.filter)
        var parts: [String] = []
        if filterOption != .all { parts.append(filterOption.title) }
        if let accountDisplayName { parts.append(accountDisplayName) }
        return parts.isEmpty ? nil : parts.joined(separator: " ・ ")
    }
}
