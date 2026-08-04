import SwiftUI

/// 通知の本体タップ専用の遷移先 — タップ直後にまずこの画面へ遷移し、対象
/// メールの解決 (`AppEnvironment.resolvePushNotificationOpenTarget`:
/// ローカル照合 → 未同期なら INBOX 優先同期 → 再照合) をこの画面の中で
/// 行う。以前は `AppDelegate` が解決し切ってから遷移していたため、未同期
/// メールだと同期が終わるまで何も起きず、失敗すると受信トレイのまま何も
/// 表示されなかった (実機報告「通知からメールを開くと表示されないことが
/// ある」)。
///
/// 解決に成功したら route を付け替えずこの場で `ThreadEntryView` に差し
/// 替える (`phase` の切り替えだけ) — pop/push の連鎖を挟まないので、
/// `MailScreenView` 側の navigation 状態と競合しない。失敗時は再試行
/// ボタン付きのエラー表示に落ちる。
struct PushNotificationOpenView: View {
    let accountId: String
    let uidNext: Int
    var onReply: (Int64, Bool) -> Void = { _, _ in }
    var onForward: (Int64) -> Void = { _ in }
    var onSearchFromSender: ((String) -> Void)?
    var onThreadRemoved: ((Int64) -> Void)?

    @Environment(AppEnvironment.self) private var environment

    private enum Phase: Equatable {
        case loading
        case resolved(threadId: Int64, messageId: Int64)
        case failed
    }

    @State private var phase: Phase = .loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                loadingContent
            case .resolved(let threadId, let messageId):
                ThreadEntryView(
                    threadId: threadId, preselectedMessageId: messageId, onReply: onReply, onForward: onForward,
                    onSearchFromSender: onSearchFromSender, onThreadRemoved: onThreadRemoved
                )
            case .failed:
                failedContent
            }
        }
        .task(resolve)
    }

    private var loadingContent: some View {
        VStack(spacing: OtegamiSpacing.md) {
            ProgressView()
            Text("メールを読み込んでいます…")
                .font(OtegamiFont.body())
                .foregroundStyle(OtegamiColor.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OtegamiColor.background)
        .accessibilityIdentifier("pushOpen.loading")
    }

    private var failedContent: some View {
        ContentUnavailableView {
            Label("メールを読み込めませんでした", systemImage: "envelope.badge")
        } description: {
            Text("通信できないか、サーバー上でメールが移動・削除された可能性があります。")
        } actions: {
            Button("再試行", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .background(OtegamiColor.background)
        .accessibilityIdentifier("pushOpen.failed")
    }

    /// `.task` (初回) と再試行ボタンの両方から呼ばれる。`.failed` からの
    /// 再試行でも `.loading` に戻してから解決し直す。既に `.resolved` なら
    /// no-op (同じ view identity で `.task` が再発火した場合の保険)。
    @Sendable
    private func resolve() async {
        if case .resolved = phase { return }
        phase = .loading
        if let target = await environment.resolvePushNotificationOpenTarget(accountId: accountId, uidNext: uidNext) {
            phase = .resolved(threadId: target.threadId, messageId: target.messageId)
        } else {
            phase = .failed
        }
    }

    private func retry() {
        Task { await resolve() }
    }
}
