import SwiftUI
import OtegamiStore

/// One row inside `MessageListView`'s `List` (and, unchanged, reused by
/// `SearchTabView`'s result list) — the interactive wrapper around
/// `ThreadRowView`: tap-to-open-or-toggle-selection, 1g's swipe actions,
/// 1h's long-press-to-select, and (macOS only) the right-click context
/// menu. Pulled out of `MessageListView.swift` into its own file, on top of
/// the `docs/ci.md` "keep row-shaped views small, and keep the `ForEach`
/// call site itself down to one function call" discipline that file's own
/// history already established — this row grew two `.swipeActions` groups,
/// a long-press gesture, and a conditional context menu on top of what was
/// already flagged as risky before design-phase-2, so isolating it in its
/// own file keeps `MessageListView.swift`'s own body-adjacent code smaller
/// too.
///
/// A real XCUITest regression while building this (`OtegamiM3SwipeActionsUITests
/// .testSwipeMarksMessageRead`, `row.swipeRight()` no longer revealing the
/// leading swipe action) turned out to have nothing to do with this row's
/// own code — see that test's updated doc comment: the new bottom tab bar
/// (1a, absent before design-phase-2) shrinks the message list's visible
/// height, and the specific seeded row that test targets ended up sitting
/// too close to the now-closer bottom edge for `swipeRight()` to reveal
/// reliably, the same "row too close to a viewport edge" class of issue
/// `testSwipeDeletesMessageOffline` already had to nudge around for a
/// different row. Recorded here too since it cost significant investigation
/// time to isolate from a genuine code regression.
struct MessageListRow: View {
    /// D8 「スワイプの割り当て」— see `SwipeActionSettingsStore`'s doc comment.
    /// Read directly via `@AppStorage` rather than threaded in as
    /// parameters (same reasoning as that type's doc comment).
    @AppStorage(SwipeActionSettingsStore.leadingShortActionKey) private var leadingShortRaw = SwipeActionSettingsStore.defaultLeadingShort.rawValue
    @AppStorage(SwipeActionSettingsStore.leadingLongActionKey) private var leadingLongRaw = SwipeActionSettingsStore.defaultLeadingLong.rawValue
    @AppStorage(SwipeActionSettingsStore.trailingShortActionKey) private var trailingShortRaw = SwipeActionSettingsStore.defaultTrailingShort.rawValue
    @AppStorage(SwipeActionSettingsStore.trailingLongActionKey) private var trailingLongRaw = SwipeActionSettingsStore.defaultTrailingLong.rawValue

    private var leadingShort: SwipeAction { SwipeAction(rawValue: leadingShortRaw) ?? SwipeActionSettingsStore.defaultLeadingShort }
    private var leadingLong: SwipeAction { SwipeAction(rawValue: leadingLongRaw) ?? SwipeActionSettingsStore.defaultLeadingLong }
    private var trailingShort: SwipeAction { SwipeAction(rawValue: trailingShortRaw) ?? SwipeActionSettingsStore.defaultTrailingShort }
    private var trailingLong: SwipeAction { SwipeAction(rawValue: trailingLongRaw) ?? SwipeActionSettingsStore.defaultTrailingLong }

    /// The short action always shows; the long action only shows if it
    /// differs from the short one (assigning the same action to both slots
    /// would otherwise render two identical buttons in the same group).
    private func slots(short: SwipeAction, long: SwipeAction) -> [SwipeAction] {
        short == long ? [short] : [short, long]
    }

    let summary: ThreadSummary
    let threadId: Int64
    /// Forwarded straight to `ThreadRowView` — see its own doc comment on
    /// `showsAccountAccent`/`accountDisplayName`.
    let accountDisplayName: String?
    let showsAccountAccent: Bool
    let isSelecting: Bool
    let isSelected: Bool
    /// Normal (not-selecting) tap: open the thread.
    let onSelect: (Int64) -> Void
    /// A tap while already in selection mode: toggle this row's checkbox
    /// instead of navigating.
    let onToggleSelection: (Int64) -> Void
    /// Long press: enter selection mode with this row pre-selected. A no-op
    /// on macOS (the gesture itself is `#if os(iOS)`-only below — macOS
    /// keeps its existing right-click context menu instead, per `CLAUDE.md`
    /// ’s "macOS は既存のコンテキストメニューを維持").
    let onEnterSelection: (Int64) -> Void
    let onToggleRead: (ThreadSummary) -> Void
    let onArchive: (ThreadSummary) -> Void
    let onDelete: (ThreadSummary) -> Void
    /// D8: 迷惑メールにする — moves to the account's Junk-role mailbox (self-
    /// healing to a freshly-created "Junk" mailbox the same way delete
    /// self-heals to Trash — see `OpQueueProcessor.resolveOrCreateJunkMailbox`).
    let onJunk: (ThreadSummary) -> Void
    /// E9: ピン留め — see `MessageListView.togglePin(_:)`'s doc comment for
    /// why this toggles every message in the thread together rather than
    /// just the row's own `latestMessage`.
    let onPin: (ThreadSummary) -> Void
    let onAppear: (ThreadSummary) -> Void

    var body: some View {
        Button(action: handleTap) {
            ThreadRowView(
                summary: summary,
                accountDisplayName: accountDisplayName,
                showsAccountAccent: showsAccountAccent,
                isSelecting: isSelecting,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("messageList.row.\(threadId)")
        // Design system: `List` draws its own default (system-styled)
        // separators and gives each row standard insets/background — both
        // fight `ThreadRowView`'s own flat/full-bleed styling, so this row
        // opts out of both and lets `ThreadRowView` own its full visual
        // bounds. 表示・操作改善バッチ「カード状表示」: `.listRowInsets` now
        // carries real horizontal/vertical margin instead of `.zero` — that
        // margin *is* the gap between cards (and from the screen edge),
        // replacing the previous full-bleed-row + dashed-divider look
        // (`.otegamiRowDivider()`) with `ThreadRowView.otegamiCardBorder()`'s
        // bordered "面" per row.
        .listRowInsets(EdgeInsets(top: OtegamiSpacing.xs, leading: OtegamiSpacing.sm, bottom: OtegamiSpacing.xs, trailing: OtegamiSpacing.sm))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        // D8 「スワイプの割り当て」— see `SwipeActionSettingsStore`'s doc
        // comment for the "short=first declared, long=second declared,
        // guarded actions never auto-fire" design this implements.
        .swipeActions(edge: .leading, allowsFullSwipe: !leadingShort.isGuardedFromFullSwipe) {
            swipeButtons(for: slots(short: leadingShort, long: leadingLong))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: !trailingShort.isGuardedFromFullSwipe) {
            swipeButtons(for: slots(short: trailingShort, long: trailingLong))
        }
        #if os(macOS)
        .contextMenu {
            contextMenuContent
        }
        #endif
        #if os(iOS)
        // 1h: long-press enters bulk-selection mode. `.simultaneousGesture`
        // rather than `.onLongPressGesture`/`.gesture` deliberately — the
        // latter two exclusively claim the touch, which risks starving
        // `List`'s own built-in `.swipeActions` pan-gesture recognizer of
        // the same touch-down event (both are recognized starting from the
        // same gesture origin). `.simultaneousGesture` lets both recognizers
        // race normally — a long, mostly-vertical-or-stationary press still
        // recognizes as a long press, while a horizontal drag (a swipe)
        // still gets recognized by `.swipeActions`' own recognizer as
        // before.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                onEnterSelection(threadId)
            }
        )
        #endif
        .onAppear {
            onAppear(summary)
        }
    }

    private func handleTap() {
        if isSelecting {
            onToggleSelection(threadId)
        } else {
            onSelect(threadId)
        }
    }

    /// D8: builds one button per entry in `actions`, in order — declaration
    /// order is what decides which one SwiftUI auto-fires on a full swipe
    /// (always the first — see `body`'s `.swipeActions` doc comment).
    @ViewBuilder
    private func swipeButtons(for actions: [SwipeAction]) -> some View {
        ForEach(actions) { action in
            swipeButton(for: action)
        }
    }

    /// Dispatches one `SwipeAction` to its callback/label/tint — shared by
    /// both edges' `swipeButtons(for:)` and (unstyled, via `Button` without
    /// `.tint`) macOS's `contextMenuContent`.
    @ViewBuilder
    private func swipeButton(for action: SwipeAction) -> some View {
        switch action {
        case .toggleRead:
            Button { onToggleRead(summary) } label: { toggleReadLabel }
                .tint(OtegamiColor.accent)
                .accessibilityIdentifier("messageList.row.\(threadId).toggleRead")
        case .archive:
            Button { onArchive(summary) } label: { Label(action.title, systemImage: action.systemImage) }
                .tint(OtegamiColor.paleBaseStrongest)
                .accessibilityIdentifier("messageList.row.\(threadId).archive")
        case .junk:
            Button { onJunk(summary) } label: { Label(action.title, systemImage: action.systemImage) }
                .tint(OtegamiColor.destructive)
                .accessibilityIdentifier("messageList.row.\(threadId).junk")
        case .pin:
            Button { onPin(summary) } label: { pinLabel }
                .tint(OtegamiColor.accentText)
                .accessibilityIdentifier("messageList.row.\(threadId).pin")
        case .delete:
            Button(role: .destructive) { onDelete(summary) } label: { Label(action.title, systemImage: action.systemImage) }
                .tint(OtegamiColor.destructive)
                .accessibilityIdentifier("messageList.row.\(threadId).delete")
        }
    }

    @ViewBuilder
    private var toggleReadLabel: some View {
        if summary.thread.unreadCount > 0 {
            Label("既読にする", systemImage: "envelope.open")
        } else {
            Label("未読にする", systemImage: "envelope.badge")
        }
    }

    @ViewBuilder
    private var pinLabel: some View {
        if summary.thread.isPinned {
            Label("ピン留めを解除", systemImage: "pin.slash")
        } else {
            Label("ピン留め", systemImage: "pin")
        }
    }

    #if os(macOS)
    /// D8: macOS has no swipe gesture, so every assignable action (not just
    /// whatever's currently assigned to a swipe slot) is always available
    /// here — `CLAUDE.md`'s "スワイプが無い macOS ではコンテキストメニューに反映する"
    /// requirement.
    @ViewBuilder
    private var contextMenuContent: some View {
        ForEach(SwipeAction.allCases) { action in
            swipeButton(for: action)
        }
    }
    #endif
}
