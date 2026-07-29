import SwiftUI

/// M10: macOS menu commands (`OtegamiCommands`) need to invoke actions that
/// live on whatever view is currently on screen (composing a new message,
/// replying to/deleting the open thread, focusing the search field) —
/// `FocusedSceneValue` is the standard SwiftUI channel for a `Commands`
/// builder (which has no view identity of its own) to reach those actions
/// without every view reimplementing its own menu-bar wiring. Every key
/// here is a plain `() -> Void` published by whichever view currently
/// "owns" that action; `Commands`-declared `Button`s read them via
/// `@FocusedValue` and disable themselves when `nil` (nothing to act on).
extension FocusedValues {
    private struct NewMessageActionKey: FocusedValueKey {
        typealias Value = () -> Void
    }

    private struct ReplyActionKey: FocusedValueKey {
        typealias Value = () -> Void
    }

    private struct DeleteActionKey: FocusedValueKey {
        typealias Value = () -> Void
    }

    /// Task #165 (macOS 操作体系再設計): ⌘E — mirrors `deleteAction`'s own
    /// "published only while a thread is open" gating.
    private struct ArchiveActionKey: FocusedValueKey {
        typealias Value = () -> Void
    }

    /// Task #165: ⌘⇧U — toggles read/unread, matching `MessageListRow
    /// .toggleReadLabel`'s existing state-dependent direction (mark read if
    /// any message in the open thread is unread, mark unread otherwise).
    private struct ToggleReadActionKey: FocusedValueKey {
        typealias Value = () -> Void
    }

    /// Task #165: ⌘⇧R — "全員に返信", the `replyAll: true` half of the same
    /// `RootView.replyToSelectedThread`-style resolution `replyAction`
    /// already uses for a plain reply.
    private struct ReplyAllActionKey: FocusedValueKey {
        typealias Value = () -> Void
    }

    /// Task #165: ⌘⇧F — "転送". Reassigns the key equivalent this app used
    /// for search-field focus before this task (`focusSearchAction`'s doc
    /// comment) — see `OtegamiCommands`'s doc comment on why `⌘⇧F` had to
    /// move to Forward (real Mail.app parity) and search moved to the now-free
    /// `⌘F` instead.
    private struct ForwardActionKey: FocusedValueKey {
        typealias Value = () -> Void
    }

    private struct FocusSearchActionKey: FocusedValueKey {
        typealias Value = () -> Void
    }

    private struct NextMailboxActionKey: FocusedValueKey {
        typealias Value = () -> Void
    }

    private struct PreviousMailboxActionKey: FocusedValueKey {
        typealias Value = () -> Void
    }

    /// Always published by `RootView` while at least one account exists
    /// (mirrors the sidebar's "作成" toolbar button's own `.disabled`
    /// condition) — ⌘N.
    var newMessageAction: (() -> Void)? {
        get { self[NewMessageActionKey.self] }
        set { self[NewMessageActionKey.self] = newValue }
    }

    /// Published only while a thread is open (`RootView.selectedThreadId
    /// != nil`) — replies to that thread's newest message, the same
    /// message `ThreadDetailView` expands by default. ⌘R.
    var replyAction: (() -> Void)? {
        get { self[ReplyActionKey.self] }
        set { self[ReplyActionKey.self] = newValue }
    }

    /// Published only while a thread is open — moves it to Trash the same
    /// way `MessageListView`'s trailing swipe action does. ⌘⌫.
    var deleteAction: (() -> Void)? {
        get { self[DeleteActionKey.self] }
        set { self[DeleteActionKey.self] = newValue }
    }

    /// Task #165: published only while a thread is open. ⌘E.
    var archiveAction: (() -> Void)? {
        get { self[ArchiveActionKey.self] }
        set { self[ArchiveActionKey.self] = newValue }
    }

    /// Task #165: published only while a thread is open. ⌘⇧U.
    var toggleReadAction: (() -> Void)? {
        get { self[ToggleReadActionKey.self] }
        set { self[ToggleReadActionKey.self] = newValue }
    }

    /// Task #165: published only while a thread is open. ⌘⇧R.
    var replyAllAction: (() -> Void)? {
        get { self[ReplyAllActionKey.self] }
        set { self[ReplyAllActionKey.self] = newValue }
    }

    /// Task #165: published only while a thread is open. ⌘⇧F.
    var forwardAction: (() -> Void)? {
        get { self[ForwardActionKey.self] }
        set { self[ForwardActionKey.self] = newValue }
    }

    /// Published by `MessageListView` while it's on screen — focuses its
    /// `.searchable` field via `.searchFocused(_:)`. ⌘⇧F.
    var focusSearchAction: (() -> Void)? {
        get { self[FocusSearchActionKey.self] }
        set { self[FocusSearchActionKey.self] = newValue }
    }

    /// Published by `RootView` whenever at least one account exists —
    /// cycles the sidebar selection to the next/previous mailbox (unified
    /// inbox, then every account's mailboxes in sidebar order). ⌘] / ⌘[.
    var nextMailboxAction: (() -> Void)? {
        get { self[NextMailboxActionKey.self] }
        set { self[NextMailboxActionKey.self] = newValue }
    }

    var previousMailboxAction: (() -> Void)? {
        get { self[PreviousMailboxActionKey.self] }
        set { self[PreviousMailboxActionKey.self] = newValue }
    }
}
