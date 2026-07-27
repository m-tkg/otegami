import Foundation
import OtegamiStore

/// Identifies one selected mailbox in the sidebar — the pair `SidebarView`
/// hands to `MessageListView`, and `MessageListView` uses to observe the
/// right `message`/`thread` rows and to know which account to sync/
/// authenticate against on refresh.
struct MailboxSelection: Hashable, Sendable {
    var accountId: String
    var mailboxId: Int64
}

/// What's selected in the sidebar (M4): either one specific mailbox, the
/// cross-account "すべての受信トレイ" unified inbox at the top of the list, or
/// (画面構造改修バッチ Task #33, 3) any other role's own cross-account
/// "横断ビュー" — `FolderListSheet`'s category-first grouping mode offers one
/// per role section, e.g. "すべてのアーカイブ". `List(selection:)`'s tag/
/// selection type, and `MessageListView`'s input — every case ultimately
/// observes `OtegamiStore.ThreadQuery` rows, just scoped differently (one
/// mailbox's threads vs. every account's `role`-role mailbox threads,
/// date-merged; `.unifiedInbox` and `.unifiedRole(.inbox)` would in fact
/// query identically, but are kept as separate cases since only
/// `.unifiedInbox` carries `MessageListView.unifiedInboxAccountFilter`'s
/// per-account filter chip — `.unifiedRole` always spans every account).
enum SidebarSelection: Hashable, Sendable {
    case unifiedInbox
    case mailbox(MailboxSelection)
    case unifiedRole(MailboxRoleRecord)
}
