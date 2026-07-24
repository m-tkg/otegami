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
