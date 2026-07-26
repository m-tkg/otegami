import Foundation
import OtegamiStore

/// 1j "フィルタチップ（全部・添付・未読・英語）" — applied client-side, after
/// `SearchQuery.threadSummaries` already returned its (FTS/LIKE-matched)
/// results. Deliberately not a `SearchQuery` parameter: every one of these
/// is a cheap in-memory predicate over fields the query already fetched
/// (`hasAttachments`, `unreadCount`, `detectedLanguage`), so re-querying
/// GRDB for each chip tap would be strictly more work for the same result,
/// and re-filtering client-side keeps the debounced-search round trip
/// (`SearchTabView.performSearch`) the one and only place that talks to the
/// database.
enum SearchFilterOption: String, CaseIterable, Identifiable {
    case all
    case attachments
    case unread
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .attachments: "添付"
        case .unread: "未読"
        case .english: "英語"
        }
    }

    func matches(_ summary: ThreadSummary) -> Bool {
        switch self {
        case .all:
            true
        case .attachments:
            summary.latestMessage?.hasAttachments == true
        case .unread:
            summary.thread.unreadCount > 0
        case .english:
            summary.latestMessage?.detectedLanguage == "en"
        }
    }
}
