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
                    .foregroundStyle(OtegamiColor.accentText)
            }
            .accessibilityIdentifier("undoToast.undoButton")
        }
        .padding(.horizontal, OtegamiSpacing.lg)
        .padding(.vertical, OtegamiSpacing.md)
        .background(OtegamiColor.ink)
        .overlay(Rectangle().strokeBorder(OtegamiColor.divider, lineWidth: OtegamiStroke.secondary))
        .padding(.horizontal, OtegamiSpacing.lg)
        .padding(.bottom, OtegamiSpacing.md)
        .accessibilityIdentifier("undoToast")
        .accessibilityElement(children: .combine)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
