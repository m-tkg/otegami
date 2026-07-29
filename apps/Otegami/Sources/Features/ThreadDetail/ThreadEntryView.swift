import SwiftUI
import OtegamiCore
import OtegamiStore

/// Task #136 (実機フィードバック「スレッド表示 ON の本文画面をアコーディオンに
/// 戻してほしい」): a thin pass-through to `ThreadDetailView` again — see
/// `docs/design-system.md`'s Task #136 節 for the full before/after. This
/// type used to (画面構造改修バッチ Task #33, 1) read the thread's message
/// count itself and, for 2+ messages, interpose `ThreadSelectionView` (a
/// separate "pick one message" screen) before ever reaching
/// `ThreadDetailView`, which in turn only ever rendered that one picked
/// message — the multi-message accordion `ThreadDetailView` itself already
/// implements (`ThreadMessageRow`/`showsHeader`, still there — see its own
/// doc comment) was reachable from iOS only for a degenerate 1-message
/// thread. Real-device feedback asked for that accordion back as the direct
/// landing screen, so this view no longer does any of its own message-count
/// lookup or branching — it just decides *which* of `ThreadDetailView`'s two
/// existing modes applies, from `preselectedMessageId` alone, and always did
/// have to make exactly this decision even when `ThreadSelectionView`
/// existed:
/// - **`preselectedMessageId` non-`nil`**: a flat-mode row (or flat search
///   result) that already knows exactly which single message it wants —
///   `singleMessageId: preselectedMessageId, isFlatModeEntry: true` (see
///   `ThreadDetailView.isFlatModeEntry`'s doc comment for why the flag is
///   `true` here specifically — suppresses "次のメールを開く"'s ambiguity
///   for a flat-mode close).
/// - **`preselectedMessageId == nil`**: a grouped-mode thread (row or
///   search result). `singleMessageId: nil, isFlatModeEntry: false` lets
///   `ThreadDetailView.load()` take its live, whole-thread
///   `ThreadQuery.messagesObservation(threadId:)` path — the same path
///   macOS's `OtegamiApp.detailColumn` already uses directly (untouched by
///   either this batch or Task #33, `CLAUDE.md`'s 1a-is-compact-only
///   scoping) — which pins the thread's *newest* message expanded and
///   collapses the rest, degenerating to "one row, always expanded, nothing
///   to collapse" for a thread that only ever had 1 message (that view's own
///   doc comment already documented this fallback; it just wasn't reachable
///   from iOS's push navigation before this revert).
///
/// No longer touches `environment.database` at all — the message-count
/// read this view used to do (`ThreadQuery.messages(threadId:db:)`, once,
/// to decide 1-vs-2+) doesn't exist anymore; `ThreadDetailView.load()`
/// already re-derives everything this view previously duplicated
/// (`accountId`/`accountLabelColorKey` included, via `environment.accounts`
/// inside its own `load()`/`messageRow(for:containerSize:)`).
struct ThreadEntryView: View {
    let threadId: Int64
    /// A flat-mode row (`ListDisplaySettingsStore.threadingKey` OFF) already
    /// knows exactly which single message it wants open —
    /// `MessageListView.selectedMessageId`'s doc comment. Non-`nil` here
    /// selects `ThreadDetailView`'s flat/single-message mode directly, with
    /// no further lookup.
    let preselectedMessageId: Int64?
    var onReply: (Int64, Bool, Bool) -> Void = { _, _, _ in }
    var onForward: (Int64) -> Void = { _ in }
    var onSearchFromSender: ((String) -> Void)?
    var onThreadRemoved: ((Int64) -> Void)?

    var body: some View {
        ThreadDetailView(
            threadId: threadId,
            singleMessageId: preselectedMessageId,
            isFlatModeEntry: preselectedMessageId != nil,
            onReply: onReply, onForward: onForward,
            onSearchFromSender: onSearchFromSender, onThreadRemoved: onThreadRemoved
        )
    }
}
