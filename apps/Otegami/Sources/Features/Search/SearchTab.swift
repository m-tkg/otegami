import Foundation

/// 検索画面再構成 (Task #86)「履歴」「保存済み」タブ — `searchText`が空の
/// あいだ (`SearchScreenView.isActive == false`) だけ表示される、検索結果
/// より上位の切り替え。
enum SearchTab: String, CaseIterable, Identifiable {
    case history
    case saved

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: String(localized: "履歴")
        case .saved: String(localized: "保存済み")
        }
    }
}
