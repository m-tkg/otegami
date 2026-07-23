import Foundation

/// Identifies one selected mailbox in the sidebar — the pair `SidebarView`
/// hands to `MessageListView`, and `MessageListView` uses to observe the
/// right `message` rows and to know which account to sync/authenticate
/// against on refresh.
struct MailboxSelection: Hashable, Sendable {
    var accountId: String
    var mailboxId: Int64
}
