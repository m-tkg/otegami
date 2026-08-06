import SwiftUI

/// 検索の IMAP サーバーサイド SEARCH フォールバック: ローカル検索結果一覧の
/// 末尾に常に表示する行 (結果 0 件のときも) — タップすると
/// `SearchScreenView`がサーバー検索を実行する。自動発動しない (タップが
/// 唯一のトリガー)。CLAUDE.md の「SwiftUI ビューは小さく保つこと」に従い、
/// `SearchScreenView.body`から状態表示部分だけを切り出した小さな View。
///
/// 状態 (未実行/実行中/エラー) の見た目だけを担い、実際のサーバー検索
/// ロジック・ヒットの描画は呼び出し元 (`SearchScreenView`) 側 — ヒットは
/// 既存の`ThreadRowView`をそのまま再利用するため、この型は行の中身を知る
/// 必要が無い。
struct ServerSearchTriggerRow: View {
    var isSearching: Bool
    var errorMessage: String?
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: OtegamiSpacing.sm) {
                statusIcon
                VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
                    Text("サーバーで検索")
                        .font(OtegamiFont.body())
                        .foregroundStyle(OtegamiColor.ink)
                    subtitle
                }
            }
        }
        .disabled(isSearching)
        .accessibilityIdentifier("search.serverSearch.trigger")
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isSearching {
            ProgressView()
        } else {
            Image(systemName: "server.rack")
                .foregroundStyle(OtegamiColor.inkSecondary)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let errorMessage {
            // 動的文字列 (エラーメッセージ) は `Text(verbatim:)` で素通しする
            // — `AccountFilterChip.label`の教訓コメントと同じ理由。
            Text(verbatim: errorMessage)
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.destructive)
                .accessibilityIdentifier("search.serverSearch.error")
        } else {
            Text("ローカルに無い古いメールもサーバー上で検索します")
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkSecondary)
        }
    }
}
