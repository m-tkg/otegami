import Foundation

/// 新画面構成 (3): メール本文画面のフッターツールバーに出すアイコンとその並び順。
/// 5つのアクションすべてが常に存在し (`allCases` が唯一の情報源 — 有効/無効の
/// 概念はない)、ユーザーが変えられるのは並び順だけ。「その他」を含めて自由に
/// 並び替えられる (固定位置を強制していない) — ユーザーが「その他」を先頭に
/// 置きたい、といった好みも尊重する。
enum MessageToolbarAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case reply
    case forward
    case search
    case info
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reply: "返信"
        case .forward: "転送"
        case .search: "検索"
        case .info: "情報"
        case .more: "その他"
        }
    }

    var systemImage: String {
        switch self {
        case .reply: "arrowshape.turn.up.left"
        case .forward: "arrowshape.turn.up.right"
        case .search: "magnifyingglass"
        case .info: "info.circle"
        case .more: "ellipsis.circle"
        }
    }
}

/// `messageToolbar.order` に `MessageToolbarAction.rawValue` をカンマ区切りで
/// 永続化する — `SwipeActionSettingsStore`と同じ「素の `UserDefaults` キーの
/// 集まり、複雑な業務ロジックは持たない」方針 (JSON より軽く、この程度の小さい
/// 固定集合の並び順にはこれで十分)。
enum MessageToolbarSettingsStore {
    static let orderKey = "messageToolbar.order"

    static let defaultOrder: [MessageToolbarAction] = [.reply, .forward, .search, .info, .more]

    /// 保存された並び順を読む。キーが未設定、または保存後にアクション集合が
    /// 変わった (このバージョンアップで新しいアクションが増えた等) 場合でも
    /// クラッシュせず安全に既定値へフォールバックする — 保存文字列から
    /// `MessageToolbarAction` に解決できたものだけを残し、まだ含まれていない
    /// アクションは末尾に追記する。
    static func loadOrder() -> [MessageToolbarAction] {
        guard let raw = UserDefaults.standard.string(forKey: orderKey), !raw.isEmpty else {
            return defaultOrder
        }
        var order = raw.split(separator: ",").compactMap { MessageToolbarAction(rawValue: String($0)) }
        for action in MessageToolbarAction.allCases where !order.contains(action) {
            order.append(action)
        }
        return order
    }

    static func saveOrder(_ order: [MessageToolbarAction]) {
        UserDefaults.standard.set(order.map(\.rawValue).joined(separator: ","), forKey: orderKey)
    }
}
