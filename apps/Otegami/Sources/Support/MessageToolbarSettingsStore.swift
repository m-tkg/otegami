import Foundation
import OtegamiCore

/// 新画面構成 (3): メール本文画面のフッターツールバーに出すアイコンとその並び順。
/// Task #88 (「要約と翻訳のボタンをフローティングをやめてツールバーに入れて」)
/// までは5アクション、それ以降は`summarize`/`translate`を加えた7アクション
/// (`allCases`が全アクションの唯一の情報源)。
///
/// Task #100 (「フッターツールバーのカスタマイズ」) 以降、ユーザーが変えられる
/// のは並び順に加えて**表示/非表示のトグル**: 非表示にしたアクションは
/// ツールバーから消えるのではなく「その他」メニューの中に移動する
/// (`MessageDetailFooterToolbar`のdoc comment参照)。**`more`(「その他」)
/// 自身だけは例外** — 非表示にできず、常に最後尾固定 (それ自身が「非表示に
/// したアクションの置き場」なので、隠したり動かしたりできては本末転倒に
/// なるため)。`MessageToolbarSettingsStore`の並び替え・可視性の実データは
/// `MessageToolbarItemSetting`の配列 (`loadItems()`/`saveItems(_:)`)。
///
/// `summarize`/`translate`はメッセージ次第で意味を持たない (本文未読込・
/// この端末で翻訳/要約が使えない・翻訳不要な言語、等) 場合があるが、
/// それは「ユーザーが明示的に非表示にした」とは別の話 — 表示オンのままの
/// 状態を指す (アイコン自体は出したまま`MessageDetailFooterToolbar`側で
/// グレーアウト表示にするに留める、`MessageDetailAIFeaturesState`経由)。
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

/// 1アクションぶんの保存状態 (アクション本体 + 表示/非表示) —
/// `MessageToolbarPreferencesCoding`の`MessageToolbarItemPreference`
/// (プレーンな`String` id版) を、この画面向けに`MessageToolbarAction`へ
/// 解決し直したもの。
struct MessageToolbarItemSetting: Identifiable, Equatable, Sendable {
    let action: MessageToolbarAction
    var isVisible: Bool

    var id: MessageToolbarAction.ID { action.id }
}

/// `messageToolbar.order` に「並び順 + 表示/非表示」を永続化する —
/// `SwipeActionSettingsStore`と同じ「素の `UserDefaults` キーの集まり、
/// 複雑な業務ロジックは持たない」方針 (JSON より軽く、この程度の小さい
/// 固定集合にはこれで十分)。実際の文字列パース・移行・不変条件
/// (「その他」は常に可視・常に末尾) の強制は`OtegamiCore`の
/// `MessageToolbarPreferencesCoding`(`String` id ベースの純粋関数、
/// `swift test`で単体テストできる — この型はアプリターゲット側にあり
/// XCUITest 以外の単体テスト手段が無いため) にすべて委譲し、この型は
/// `MessageToolbarAction` との変換と`UserDefaults`の読み書きだけを担う。
///
/// **Task #100 での後方互換**: キー名は変えていない
/// (`AppSettingsCloudDirectory`のiCloud同期許可リストがこの同じキーを
/// 使い続けられる)。旧形式 (`"reply,forward,..."`、可視性の概念が無い、
/// 各トークンに`:0`/`:1`サフィックスが無い) はそのまま読める —
/// `MessageToolbarPreferencesCoding`のdoc comment参照。可視性サフィックス
/// 無しのトークンは「表示」として扱われるので、既存ユーザーの保存済み
/// 並び順は全項目表示のまま、その並びだけを引き継ぐ。
enum MessageToolbarSettingsStore {
    static let orderKey = "messageToolbar.order"

    // Task #88: 要約/翻訳は「返信/転送/検索/情報」という既存メッセージ操作
    // 群のすぐ後ろ、「その他」の手前に置く — フローティング時代の見た目の
    // 並び (要約が上、翻訳がその下) をそのまま左→右の順序に対応させた。
    static let defaultOrder: [MessageToolbarAction] = [.reply, .forward, .search, .info, .summarize, .translate, .more]

    /// 非表示にできず・並び替えもできず・常に末尾固定の唯一のアクション。
    private static let pinnedTrailingAction = MessageToolbarAction.more

    private static var knownIDs: [String] { defaultOrder.map(\.rawValue) }

    static var defaultItems: [MessageToolbarItemSetting] {
        defaultOrder.map { MessageToolbarItemSetting(action: $0, isVisible: true) }
    }

    /// 保存された並び順 + 可視性を読む。キーが未設定、旧形式、または保存後に
    /// アクション集合が変わった (このバージョンアップで新しいアクションが
    /// 増えた等) 場合でもクラッシュせず安全に解決する
    /// (`MessageToolbarPreferencesCoding.parse`の不変条件)。
    static func loadItems() -> [MessageToolbarItemSetting] {
        let preferences = MessageToolbarPreferencesCoding.parse(
            raw: UserDefaults.standard.string(forKey: orderKey),
            knownIDs: knownIDs,
            pinnedTrailingID: pinnedTrailingAction.rawValue
        )
        return decode(preferences)
    }

    static func saveItems(_ items: [MessageToolbarItemSetting]) {
        UserDefaults.standard.set(encodedRawValue(for: items), forKey: orderKey)
    }

    /// `AppSettingsCloudDirectory`がキー未設定時のフォールバック値として
    /// 使う既定値の生文字列表現 — 生成ロジックをここに一箇所に集約する。
    static func encodedRawValue(for items: [MessageToolbarItemSetting]) -> String {
        MessageToolbarPreferencesCoding.encode(encode(items), knownIDs: knownIDs, pinnedTrailingID: pinnedTrailingAction.rawValue)
    }

    /// ツールバー本体 (`MessageDetailFooterToolbar`) がアイコンとして描画する、
    /// 表示オンのアクションだけの並び。
    static func visibleOrder(_ items: [MessageToolbarItemSetting]) -> [MessageToolbarAction] {
        items.filter(\.isVisible).map(\.action)
    }

    /// 「その他」メニューに追加で並べる、表示オフのアクション
    /// (`more`自身は含まれない — 非表示にできないため)。
    static func hiddenOrder(_ items: [MessageToolbarItemSetting]) -> [MessageToolbarAction] {
        let hiddenIDs = MessageToolbarPreferencesCoding.hiddenOrder(encode(items), pinnedTrailingID: pinnedTrailingAction.rawValue)
        return hiddenIDs.compactMap { MessageToolbarAction(rawValue: $0) }
    }

    private static func encode(_ items: [MessageToolbarItemSetting]) -> [MessageToolbarItemPreference] {
        items.map { MessageToolbarItemPreference(id: $0.action.rawValue, isVisible: $0.isVisible) }
    }

    private static func decode(_ preferences: [MessageToolbarItemPreference]) -> [MessageToolbarItemSetting] {
        preferences.compactMap { preference in
            MessageToolbarAction(rawValue: preference.id).map { MessageToolbarItemSetting(action: $0, isVisible: preference.isVisible) }
        }
    }
}
