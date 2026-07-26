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
            .background(OtegamiColor.accent)
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
