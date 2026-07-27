import SwiftUI
import OtegamiStore

/// 画面構造改修バッチ (Task #33, 1): 「メール本文のエリアが狭い。スレッド表示に
/// する場合、スレッドを選ぶ画面を別で挟んで、メール本文の画面ではスレッドは
/// 出さない方がいい」— a real (2+ message) thread now lands here first
/// instead of `ThreadDetailView`'s accordion: one line per message (same
/// content a list row already shows — icon/preview/time, 指示どおり), tap to
/// push straight to that single message's body with no thread stack
/// anywhere on screen (`ThreadEntryView`'s doc comment for the "skip this
/// screen entirely for a 1-message thread" half of that same requirement).
///
/// Rows reuse `ThreadMessageSummaryRow` in `.list` mode — the same visual
/// language `ThreadDetailView`'s own (now `.accordion`-mode) rows already
/// use, just without the expand/collapse affordance this screen has no use
/// for (every row here always pushes a new screen instead of expanding in
/// place).
struct ThreadSelectionView: View {
    let messages: [MessageRecord]
    let accountId: String?
    let accountLabelColorKey: String?
    let onSelect: (Int64) -> Void

    /// 表示・操作改善バッチ「ヘッダにメール件名を表示しない」の対象は
    /// `ThreadDetailView`/`MessageView`(本文画面)であって、この選択画面自体は
    /// 「一覧」相当の中間ステップ — どのメールを開くか判断する画面でこそ件名が
    /// 要る (`MessageListView`の各行がまさにその判断材料として件名/プレビュー
    /// を出しているのと同じ理由)。最新メッセージの件名を採用: スレッドの件名は
    /// 実務上そのままか「Re:」が積み重なるだけで、最新のものが一番読みやすい。
    private var navigationTitleText: String {
        let subject = messages.last?.subject
        return subject?.isEmpty == false ? subject! : "スレッド"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(messages) { message in
                    row(for: message)
                }
            }
        }
        .accessibilityIdentifier("threadSelection.scrollView")
        .background(OtegamiColor.background)
        .navigationTitle(navigationTitleText)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func row(for message: MessageRecord) -> some View {
        if let messageId = message.id {
            Button {
                onSelect(messageId)
            } label: {
                ThreadMessageSummaryRow(message: message, accountId: accountId, accountLabelColorKey: accountLabelColorKey, mode: .list)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("threadSelection.message.\(messageId)")

            // Design system: same 1pt dashed row separator `ThreadDetailView`
            // uses between its own accordion rows.
            Rectangle()
                .fill(OtegamiColor.dividerSubtle)
                .frame(height: OtegamiStroke.secondary)
                .accessibilityHidden(true)
        }
    }
}
