import Foundation

/// 新画面構成 (3): メール本文画面のフッターツールバーに出すアイコンとその並び順。
/// Task #88 (「要約と翻訳のボタンをフローティングをやめてツールバーに入れて」)
/// までは5アクション、それ以降は`summarize`/`translate`を加えた7アクション
/// すべてが常に存在し (`allCases` が唯一の情報源 — 有効/無効の概念はない)、
/// ユーザーが変えられるのは並び順だけ。「その他」を含めて自由に並び替えられる
/// (固定位置を強制していない) — ユーザーが「その他」を先頭に置きたい、
/// といった好みも尊重する。
///
/// `summarize`/`translate`はメッセージ次第で意味を持たない (本文未読込・
/// この端末で翻訳/要約が使えない・翻訳不要な言語、等) 場合があるが、
/// それでもこの集合からは外さない — アイコン自体を出したり消したりすると
/// 並びが揺れて操作しづらくなるため、`MessageDetailFooterToolbar`側で
/// グレーアウト表示にするに留める (`MessageDetailAIFeaturesState`経由)。
enum MessageToolbarAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case reply
    case forward
    case search
    case info
    case summarize
    case translate
    case more

    var id: String { rawValue }

    // A「UI に複数言語が混在」実機報告の原因の一つ: `Text(String)`は自動で
    // ローカライズされない ("verbatim"呼び出し) — `docs/localization.md`の
    // パターン1どおり`String(localized:)`で明示的にカタログを引く
    // (`MessageToolbarSettingsView`の並び替えリストが`Text(action.title)`
    // としてこの`String`を渡すため)。
    var title: String {
        switch self {
        case .reply: String(localized: "返信")
        case .forward: String(localized: "転送")
        case .search: String(localized: "検索")
        case .info: String(localized: "情報")
        case .summarize: String(localized: "要約")
        case .translate: String(localized: "翻訳")
        case .more: String(localized: "その他")
        }
    }

    var systemImage: String {
        switch self {
        case .reply: "arrowshape.turn.up.left"
        case .forward: "arrowshape.turn.up.right"
        case .search: "magnifyingglass"
        case .info: "info.circle"
        // Task #55/#59 (旧フローティングボタン) からそのまま引き継いだ
        // アイコン — `AISummaryFloatingButton`/`TranslationFloatingButton`
        // の doc comment 参照 (どちらも Task #88 で撤去済み)。
        case .summarize: "sparkles"
        case .translate: "translate"
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

    // Task #88: 要約/翻訳は「返信/転送/検索/情報」という既存メッセージ操作
    // 群のすぐ後ろ、「その他」の手前に置く — フローティング時代の見た目の
    // 並び (要約が上、翻訳がその下) をそのまま左→右の順序に対応させた。
    static let defaultOrder: [MessageToolbarAction] = [.reply, .forward, .search, .info, .summarize, .translate, .more]

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
