import SwiftUI

/// C7 送信キャンセル: the blue countdown bar shown just below the header
/// while a `PendingSendCoordinator.PendingSend` is in flight — a solid
/// `OtegamiColor.accent` bar hosting "送信を取り消す" (per the task's explicit
/// instruction to place the cancel button *on* the bar, not as a separate
/// toast/alert) plus a thin depleting progress rail along its bottom edge
/// ("左端いっぱいから始まり、残り時間に応じて右へ減っていく").
///
/// Driven by `TimelineView(.periodic(...))` against `pending.startedAt`/
/// `.duration` directly, rather than `PendingSendCoordinator` itself ticking
/// a `@Published`-style countdown value — SwiftUI re-evaluates this view on
/// each timeline tick without the coordinator needing to know anything about
/// animation frame rates.
struct SendCountdownBar: View {
    let pending: PendingSendCoordinator.PendingSend
    let onCancel: () -> Void

    var body: some View {
        TimelineView(.periodic(from: pending.startedAt, by: 1.0 / 20.0)) { context in
            let elapsed = context.date.timeIntervalSince(pending.startedAt)
            let remaining = max(0, pending.duration - elapsed)
            let remainingFraction: Double = pending.duration > 0 ? max(0, min(1, remaining / pending.duration)) : 0

            HStack(spacing: OtegamiSpacing.sm) {
                Text("あと\(Int(remaining.rounded(.up)))秒で送信します")
                    .font(OtegamiFont.caption())
                    .lineLimit(1)
                Spacer(minLength: OtegamiSpacing.sm)
                Button("送信を取り消す", action: onCancel)
                    .font(OtegamiFont.headline())
                    .accessibilityIdentifier("sendCountdown.cancelButton")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, OtegamiSpacing.md)
            .frame(height: 44)
            // Liquid Glass Phase 4 (`docs/design-system.md`「Liquid Glass 方針」):
            // 送信取り消しはこのアプリで数少ない「compose 系の最重要
            // アクション」— 方針が tint 付き Glass (`.glassProminent`相当)
            // を許す唯一の分類なので、不透明な`accent`塗りを`accent`を
            // tint した Glass に置き換える (`MessageDetailFooterToolbar
            // .translateFootnoteCaption`と同じ`.regular.tint(_:)`手法)。
            // ヘッダ直下に全幅で張り付く既存レイアウトはそのまま (他の
            // 浮遊クロームと違いフローティングのカプセル化はしない —
            // 下端の残り時間バーが角丸で欠けるのを避けるため)。macOS は
            // このバーの唯一の呼び出し元 (`MailScreenView`→
            // `OtegamiRootView`) が iOS 専用のため実質無変更だが、他の
            // このバッチの部品と同じ理由で明示的に分岐しておく。
            #if os(iOS)
            .glassEffect(.regular.tint(OtegamiColor.accent), in: Rectangle())
            #else
            .background(OtegamiColor.accent)
            #endif
            .overlay(alignment: .bottom) {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.white.opacity(0.55))
                            .frame(width: proxy.size.width * remainingFraction)
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 3)
            }
            .accessibilityIdentifier("sendCountdown.bar")
        }
    }
}
