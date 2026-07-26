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
    /// 1l "操作" setting — see `SwipeActionSettingsStore`'s doc comment on
    /// why this is the one customizable axis. Read directly via
    /// `@AppStorage` rather than threaded in as a parameter (same
    /// reasoning as that type's doc comment).
    @AppStorage(SwipeActionSettingsStore.leadingQuickActionKey) private var leadingQuickActionRaw = LeadingSwipeQuickAction.toggleRead.rawValue
    private var leadingQuickAction: LeadingSwipeQuickAction {
        LeadingSwipeQuickAction(rawValue: leadingQuickActionRaw) ?? .toggleRead
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
        // fight `ThreadRowView`'s own flat/full-bleed styling (its
        // background already spans the row, and `.otegamiRowDivider()`
        // below draws the handoff's 1pt dashed row rule instead of the
        // system's thin solid one), so this row opts out of all three and
        // lets `ThreadRowView` own its full visual bounds.
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .otegamiRowDivider()
        // 1g: "右へ短く=既読/未読、右へ長く=アーカイブ". SwiftUI's
        // `.swipeActions` can only make *one* action (always the first
        // declared, per Apple's documentation) auto-fire on a full swipe —
        // there's no public API for two distance-based thresholds each
        // firing a *different* action. `onToggleRead` (low-stakes, trivially
        // reversible) is that one action; `onArchive` is declared second, so
        // reaching it always requires revealing the full leading group and
        // tapping explicitly — approximates "長く" as "requires swiping
        // further to even see the button", not literally "a longer swipe
        // auto-fires it".
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            leadingSwipeActions
        }
        // 1g: "左へ=（翻訳）→後で→削除。削除は最も端でハードスワイプ必須（誤爆防止）".
        // `allowsFullSwipe: false` here means *no* trailing action ever
        // auto-fires from swipe distance alone — every one (currently just
        // delete; see `trailingSwipeActions`'s doc comment for why 翻訳/後で
        // aren't rendered yet) always needs an explicit tap after revealing.
        // That's a stricter reading of "誤爆防止" than the handoff's literal
        // "delete needs a hard full swipe" (which would make delete *the*
        // full-swipe-eligible action): a swipe can never accidentally
        // trigger delete at all this way, only reveal it — recorded as an
        // intentional deviation in docs/design-system.md.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            trailingSwipeActions
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

    /// 1g/1l: declaration order here decides which of the two leading
    /// actions SwiftUI auto-fires on a full swipe (always the first one —
    /// see this type's own doc comment) — `leadingQuickAction` (1l's
    /// customizable setting) picks which that is.
    @ViewBuilder
    private var leadingSwipeActions: some View {
        switch leadingQuickAction {
        case .toggleRead:
            toggleReadButton
            archiveButton
        case .archive:
            archiveButton
            toggleReadButton
        }
    }

    private var toggleReadButton: some View {
        Button {
            onToggleRead(summary)
        } label: {
            toggleReadLabel
        }
        .tint(OtegamiColor.accent)
        .accessibilityIdentifier("messageList.row.\(threadId).toggleRead")
    }

    private var archiveButton: some View {
        Button {
            onArchive(summary)
        } label: {
            Label("アーカイブ", systemImage: "archivebox")
        }
        .tint(OtegamiColor.paleBaseStrongest)
        .accessibilityIdentifier("messageList.row.\(threadId).archive")
    }

    /// Delete-only for now — 翻訳/後で's slots are intentionally not
    /// rendered yet (`MessageListView`'s own doc comment on
    /// `translateSwipeSlot`/`laterSwipeSlot` explains why: no fake
    /// non-functional buttons shown to real users, per this task's brief —
    /// "場所だけ空けるか、後から差し込める形にしておく"). Once translation ships,
    /// insert those two buttons *before* this one in this `@ViewBuilder` so
    /// declaration order stays 翻訳→後で→削除 (nearest-the-edge to
    /// furthest, matching the handoff) — see `MessageListView`'s reserved
    /// `translateSwipeSlot`/`laterSwipeSlot` computed properties for the
    /// intended insertion point.
    private var trailingSwipeActions: some View {
        Button(role: .destructive) {
            onDelete(summary)
        } label: {
            Label("削除", systemImage: "trash")
        }
        .tint(OtegamiColor.destructive)
        .accessibilityIdentifier("messageList.row.\(threadId).delete")
    }

    @ViewBuilder
    private var toggleReadLabel: some View {
        if summary.thread.unreadCount > 0 {
            Label("既読にする", systemImage: "envelope.open")
        } else {
            Label("未読にする", systemImage: "envelope.badge")
        }
    }

    #if os(macOS)
    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            onToggleRead(summary)
        } label: {
            toggleReadLabel
        }
        Button {
            onArchive(summary)
        } label: {
            Label("アーカイブ", systemImage: "archivebox")
        }
        Button(role: .destructive) {
            onDelete(summary)
        } label: {
            Label("削除", systemImage: "trash")
        }
    }
    #endif
}
