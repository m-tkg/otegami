import Foundation

/// G「削除・アーカイブ時の挙動」: after deleting/archiving from the message
/// detail screen (`ThreadDetailView`'s "…" menu, or its swipe-equivalent
/// actions when reached from there), whether to return to the message list
/// (the pre-existing, only-ever behavior before this setting existed) or
/// open the next message in the currently-displayed order.
///
/// **Deliberately scoped to the detail screen's own delete/archive/junk
/// actions only** — `MessageListView`'s row swipe/context-menu/bulk-select
/// delete-archive-junk never had a "then what" question to begin with (the
/// row just disappears from the list you're already looking at), so this
/// setting has nothing to say there.
enum PostDeleteArchiveAction: String, CaseIterable, Identifiable {
    case backToList
    case nextMessage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backToList: String(localized: "メール一覧に戻る")
        case .nextMessage: String(localized: "次のメールを開く")
        }
    }
}

enum MessagePostActionSettingsStore {
    static let afterDeleteArchiveKey = "messageAction.afterDeleteArchive"
    /// Matches this feature's pre-existing-before-the-setting behavior
    /// exactly (`ThreadDetailView.archiveThread()`/`deleteThread()`/
    /// `junkThread()` always called `dismiss()`) — introducing this setting
    /// must not silently change anyone's existing experience.
    static let defaultAfterDeleteArchive = PostDeleteArchiveAction.backToList

    /// Given the ordered list of thread ids currently on screen (whatever
    /// order `MessageListView`'s `summaries` last reported, before
    /// `removedThreadId` was removed from the database) and which setting
    /// is in effect, resolves what the detail screen should navigate to
    /// next. `nil` means "go back to the list" — both because that's what
    /// `.backToList` always means, and as `.nextMessage`'s own fallback
    /// when there's nothing left to open (the list only had this one
    /// thread, or `removedThreadId` wasn't found in `order` at all — e.g. a
    /// stale/racy snapshot). Prefers the thread that was *after*
    /// `removedThreadId` in `order`; falls back to the one *before* it (the
    /// new "next" once the list re-renders without the removed row) rather
    /// than giving up, so deleting the very last message in the list still
    /// opens something instead of unconditionally falling back to the list.
    static func nextThreadId(after removedThreadId: Int64, in order: [Int64], action: PostDeleteArchiveAction) -> Int64? {
        guard action == .nextMessage else { return nil }
        guard let index = order.firstIndex(of: removedThreadId) else { return nil }
        let remaining = order.filter { $0 != removedThreadId }
        guard !remaining.isEmpty else { return nil }
        if index < order.count - 1 {
            // There was a next row in the original order — its id is still
            // valid and unambiguous even after the removed row's index
            // shifts everything after it.
            return order[(index + 1)...].first
        }
        // The removed thread was last in the list — open what's now the
        // new last row instead of nothing.
        return remaining.last
    }
}
