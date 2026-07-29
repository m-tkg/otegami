import SwiftUI

/// A bottom-anchored "元に戻す" (Undo) toast for a destructive action —
/// 1h's "未読/既読、フラグ、アーカイブは即時反映＋Undo（トースト）を推奨" and this
/// app's own decision (`CLAUDE.md`) to attach it specifically to
/// destructive swipe/bulk actions (delete, archive). Purely presentational:
/// callers own the timer/cancellation logic (`MessageListView`'s
/// `pendingUndo` state) and just pass the current message text + a
/// callback.
public struct UndoToast: View {
    private let message: String
    private let onUndo: () -> Void

    public init(message: String, onUndo: @escaping () -> Void) {
        self.message = message
        self.onUndo = onUndo
    }

    public var body: some View {
        HStack(spacing: OtegamiSpacing.md) {
            Text(message)
                .font(OtegamiFont.subheadline())
                .foregroundStyle(OtegamiColor.surface)
                .lineLimit(2)
            Spacer(minLength: OtegamiSpacing.sm)
            Button(action: onUndo) {
                Text("元に戻す")
                    .font(OtegamiFont.subheadline())
                    .fontWeight(.semibold)
                    // Task #108 続報: `ink` 背景上では `accentText` が沈む —
                    // 反転面専用の `accentTextOnInk` を使う (トークン側の
                    // doc comment 参照)。
                    .foregroundStyle(OtegamiColor.accentTextOnInk)
            }
            // Task #108 (c): 「元に戻す」のタップ領域を44pt以上に拡大 —
            // `AccountFilterChip`と同じ`otegamiMinimumTappable()`を使い、
            // 見た目のテキストサイズ自体は変えない。
            .otegamiMinimumTappable()
            .accessibilityIdentifier("undoToast.undoButton")
        }
        .padding(.horizontal, OtegamiSpacing.lg)
        // Task #108 (c): 実機報告「トーストが薄くて元に戻すが押しにくい」—
        // `.md`(12)→`.lg`(16)に増やし、トースト全体の高さも底上げする。
        .padding(.vertical, OtegamiSpacing.lg)
        .background(OtegamiColor.ink)
        .overlay(Rectangle().strokeBorder(OtegamiColor.divider, lineWidth: OtegamiStroke.secondary))
        .padding(.horizontal, OtegamiSpacing.lg)
        .padding(.bottom, OtegamiSpacing.md)
        .accessibilityIdentifier("undoToast")
        .accessibilityElement(children: .combine)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
