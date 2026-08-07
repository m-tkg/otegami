import SwiftUI

/// A bottom-anchored toast for a destructive-action-adjacent notice —
/// 1h's "未読/既読、フラグ、アーカイブは即時反映＋Undo（トースト）を推奨" and this
/// app's own decision (`CLAUDE.md`) to attach it specifically to
/// destructive swipe/bulk actions (delete, archive). Purely presentational:
/// callers own the timer/cancellation logic (`MessageListView`'s
/// `pendingUndo` state) and just pass the current message text + a
/// callback.
///
/// Task #163 (実機フィードバック「ピン留めされたメールはアーカイブできないように
/// してほしい」): `onUndo` is optional — a blocked-action notice (e.g. "ピン
/// 留め中のためアーカイブできません") has nothing to undo, so it passes `nil`
/// and this renders the exact same toast shell with no "元に戻す" button,
/// rather than introducing a second, visually-diverging component for what
/// is otherwise identical presentation.
public struct UndoToast: View {
    private let message: String
    private let onUndo: (() -> Void)?

    public init(message: String, onUndo: (() -> Void)? = nil) {
        self.message = message
        self.onUndo = onUndo
    }

    public var body: some View {
        HStack(spacing: OtegamiSpacing.md) {
            Text(message)
                .font(OtegamiFont.subheadline())
                .foregroundStyle(messageForegroundStyle)
                .lineLimit(2)
            Spacer(minLength: OtegamiSpacing.sm)
            if let onUndo {
                Button(action: onUndo) {
                    Text("元に戻す")
                        .font(OtegamiFont.subheadline())
                        .fontWeight(.semibold)
                        .foregroundStyle(undoForegroundStyle)
                }
                // Task #108 (c): 「元に戻す」のタップ領域を44pt以上に拡大 —
                // `AccountFilterChip`と同じ`otegamiMinimumTappable()`を使い、
                // 見た目のテキストサイズ自体は変えない。
                .otegamiMinimumTappable()
                .accessibilityIdentifier("undoToast.undoButton")
            }
        }
        .padding(.horizontal, OtegamiSpacing.lg)
        // Task #108 (c): 実機報告「トーストが薄くて元に戻すが押しにくい」—
        // `.md`(12)→`.lg`(16)に増やし、トースト全体の高さも底上げする。
        .padding(.vertical, OtegamiSpacing.lg)
        // Liquid Glass Phase 4 (`docs/design-system.md`「Liquid Glass 方針」):
        // iOS はこのトーストが唯一持っていた不透明な反転面塗り (`ink`
        // 背景 + `surface`/`accentTextOnInk`の反転前景色) をやめ、
        // `MessageDetailFooterToolbar`と同じ「クローム層はバー全体1枚の
        // Glass カプセル」に揃えた。macOS はこのトーストにこれまで独自
        // 分岐が無かった (Phase 1-3・2026-08-07 のネイティブ化はサイド
        // バー/一覧/チップ/検索欄が対象で、この浮遊トーストは含まれて
        // いなかった) — 新規に`#if os(macOS)`を切り、CLAUDE.md の
        // 「macOS は現状維持」どおり旧来の`ink`反転面をそのまま残す。
        #if os(iOS)
        .otegamiGlassChrome(shape: Capsule())
        #else
        .background(OtegamiColor.ink)
        .overlay(Rectangle().strokeBorder(OtegamiColor.divider, lineWidth: OtegamiStroke.secondary))
        #endif
        .padding(.horizontal, OtegamiSpacing.lg)
        .padding(.bottom, OtegamiSpacing.md)
        .accessibilityIdentifier("undoToast")
        .accessibilityElement(children: .combine)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// iOS: Glass の上は標準の`.primary`に委譲。macOS: 従来どおり`ink`の
    /// 濃い背景上で読める`surface`(明色)を反転面前景色として使う。
    private var messageForegroundStyle: AnyShapeStyle {
        #if os(iOS)
        AnyShapeStyle(.primary)
        #else
        AnyShapeStyle(OtegamiColor.surface)
        #endif
    }

    /// iOS: Glass 上のアクションは他のクローム部品 (`AccountFilterChip`の
    /// 選択時など) と同じ`accent`。macOS: 従来どおり`ink`背景専用の
    /// `accentTextOnInk` (`accentText`だと沈むための反転面専用トークン、
    /// Task #108 続報のコメント参照)。
    private var undoForegroundStyle: AnyShapeStyle {
        #if os(iOS)
        AnyShapeStyle(OtegamiColor.accent)
        #else
        AnyShapeStyle(OtegamiColor.accentTextOnInk)
        #endif
    }
}
