import Foundation

/// `MessageListView`'s `.searchScopes` picker values (M7, plan: "検索スコープ
/// 切替 (すべて / 現在のメールボックス) を searchable の scope で"). A thin UI-layer
/// enum, not `OtegamiStore.SearchScope` itself — `MessageListView` maps this
/// (plus the sidebar's current `SidebarSelection`) to the store's
/// `SearchScope` right before calling `SearchQuery.threadSummaries`, since
/// "現在のメールボックス" only makes sense when a specific mailbox is
/// selected (not the unified inbox).
enum SearchScopeOption: String, CaseIterable, Identifiable, Hashable {
    case all
    case currentMailbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "すべて"
        case .currentMailbox: "このメールボックス"
        }
    }
}
