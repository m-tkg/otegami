import SwiftUI
import SyncEngine

/// A top-anchored banner shown while a differential sync (pull-to-refresh,
/// the toolbar's manual re-sync) is in flight — Task #194 (実機フィードバック
/// 「Pull to refresh が長すぎて終わらない。どのくらい進んでいるのかのバーを出せる
/// なら出したい。またキャンセルもできるようにして欲しい」).
///
/// Deliberately separate from SwiftUI's own `.refreshable` pull spinner
/// (which `MessageListView` keeps as-is) rather than replacing it: the pull
/// spinner only exists while the finger is still on/near the list and stops
/// meaning anything once it springs back, but a slow sync (this task's whole
/// premise) very much keeps running after that — this banner is what stays
/// visible for as long as the sync itself does, on macOS's toolbar-button
/// refresh too (which has no pull gesture/spinner at all).
///
/// Determinate vs. indeterminate follows the task's own instruction ("総量が
/// 事前に分かる段階は割合表示、分からない段階は不定形の表示"): a phase whose
/// `SyncProgressUpdate.total` is known (currently only `.flagSync` — the
/// non-CONDSTORE flag-sync chunk count; see `MailboxSyncer
/// .refetchAndDiffFlags`'s doc comment for why *that* path in particular
/// used to be the "never finishes" one) gets a real percentage bar; every
/// other phase gets an indeterminate spinner rather than a fabricated
/// percentage.
public struct SyncProgressBanner: View {
    private let update: MailboxSyncer.SyncProgressUpdate?
    private let onCancel: () -> Void

    public init(update: MailboxSyncer.SyncProgressUpdate?, onCancel: @escaping () -> Void) {
        self.update = update
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            progressIndicator
            phaseLabel
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: OtegamiSpacing.sm)
            Button(action: onCancel) {
                Text("キャンセル")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.accentText)
            }
            .accessibilityIdentifier("syncProgressBanner.cancelButton")
        }
        .padding(.horizontal, OtegamiSpacing.md)
        .padding(.vertical, OtegamiSpacing.sm)
        .background(OtegamiColor.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OtegamiColor.dividerSubtle)
                .frame(height: OtegamiStroke.secondary)
        }
        .accessibilityIdentifier("syncProgressBanner")
        .accessibilityElement(children: .combine)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if let total = update?.total, total > 0 {
            ProgressView(value: Double(update?.completed ?? 0), total: Double(total))
                .progressViewStyle(.linear)
                .tint(OtegamiColor.accent)
                .frame(width: 60)
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(OtegamiColor.accent)
        }
    }

    /// A `@ViewBuilder` (not a `String`-returning property fed into
    /// `Text(verbatim:)`) so every case's literal goes through SwiftUI's
    /// normal `LocalizedStringKey` path and gets picked up by
    /// `scripts/generate-localizable.py`'s scan — these are fixed, curated
    /// UI copy (not user-entered/dynamic data like an account address or
    /// search query), so `Text(verbatim:)`'s "never localized" behavior
    /// (`CLAUDE.md`'s `AccountFilterChip` lesson) would be the wrong call
    /// here, not the right one.
    @ViewBuilder
    private var phaseLabel: some View {
        switch update?.phase {
        case .newMail:
            Text("新着メールを確認中…")
        case .flagSync:
            if let total = update?.total, total > 0 {
                Text("同期中… (\(update?.completed ?? 0)/\(total))")
            } else {
                Text("既読・削除状態を同期中…")
            }
        case .reconcile:
            Text("整合性を確認中…")
        case .fullResync:
            Text("メールボックスを再取得中…")
        case nil:
            Text("同期中…")
        }
    }
}
