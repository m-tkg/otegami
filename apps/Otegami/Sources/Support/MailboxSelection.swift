import Foundation

/// Identifies one selected mailbox in the sidebar — the pair `SidebarView`
/// hands to `MessageListView`, and `MessageListView` uses to observe the
/// right `message`/`thread` rows and to know which account to sync/
/// authenticate against on refresh.
struct MailboxSelection: Hashable, Sendable {
    var accountId: String
    var mailboxId: Int64
}

/// What's selected in the sidebar (M4): either one specific mailbox, or the
/// cross-account "すべての受信トレイ" unified inbox at the top of the list.
/// `List(selection:)`'s tag/selection type, and `MessageListView`'s input —
/// both branches ultimately observe `OtegamiStore.ThreadQuery` rows, just
/// scoped differently (one mailbox's threads vs. every account's inbox-role
/// mailbox threads, date-merged).
enum SidebarSelection: Hashable, Sendable {
    case unifiedInbox
    case mailbox(MailboxSelection)
}
