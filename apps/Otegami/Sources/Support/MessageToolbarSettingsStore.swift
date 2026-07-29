import Foundation
import OtegamiCore

/// 新画面構成 (3): メール本文画面のフッターツールバーに出せるアイコンの全体
/// 集合 (`allCases`が唯一の情報源)。Task #88 で要約/翻訳が加わり5→7、
/// 2026-07-29 の追加仕様でさらに「その他」メニューがネイティブに持っていた
/// 7操作 (ミュート・ピン留め・未読にする・アーカイブ・迷惑メールにする・
/// 英語で返信を下書き・削除) を一級のアクションへ昇格し7→14、Task #103
/// (「ソースを表示」) で15になった — これで「その他」の中身は「ユーザーが
/// 非表示にしたアクションの集まり」に完全に統一され、「昇格できない固定の
/// その他専用項目」という特別扱いは無くなった (唯一の例外は`more`自身と、
/// `MessageDetailFooterToolbar.onCustomizeToolbar`が開く「ツールバーを
/// カスタマイズ」— これは操作対象のメッセージに対する操作ではなく設定への
/// ショートカットなので`MessageToolbarAction`化していない、常に「その他」
/// メニュー末尾固定)。Task #139 で「英語で返信を下書き」
/// (`draftEnglishReply`) を撤去し15→14になった — 実際にはほぼ使われて
/// おらず、翻訳ボタンが常時有効になった (#138) こともあり冗長と判断された。
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
    case mute
    case pin
    case markUnread
    case archive
    case junk
    case delete
    /// Task #103 ("ソースを表示" — 表示崩れメールの eml を受け渡す調査経路):
    /// 生 RFC822 ソースをモノスペース表示 + シェアで `.eml` として書き出す。
    /// 新規追加ケースのお手本は`MessageToolbarSettingsStore.defaultItems`の
    /// doc comment のとおり — `defaultOrder`には`more`の直前に追加し、
    /// `defaultVisibleActions`には**入れない** (デフォルト非表示・「その他」
    /// メニュー内)。`MessageToolbarPreferencesCoding.parse`の「保存済み
    /// データに無い id は、その id の`defaults`エントリ自身の可視性で補う」
    /// 仕様により、この変更以前から保存済みの並びを持つユーザーにもこの
    /// 項目が自動的に「その他」入りで追加される。
    case viewSource
    case more

    var id: String { rawValue }

    // A「UI に複数言語が混在」実機報告の原因の一つ: `Text(String)`は自動で
    // ローカライズされない ("verbatim"呼び出し) — `docs/localization.md`の
    // パターン1どおり`String(localized:)`で明示的にカタログを引く
    // (`MessageToolbarSettingsView`の並び替えリストが`Text(action.title)`
    // としてこの`String`を渡すため)。
    //
    // `mute`/`pin`は状態 (ミュート中か・ピン留め中か) で見た目が変わる
    // トグル操作 — ここでの`title`/`systemImage`はあくまで設定画面の並び
    // 替えリストで使う「操作を指す固定のラベル」であって、
    // `MessageDetailFooterToolbar`がツールバーアイコン/「その他」メニュー
    // 項目として実際に描画する際は、そちらで状態に応じたラベル/アイコンに
    // 差し替える (`muteButton`/`pinButton`/`hiddenActionMenuItem(for:)`の
    // `.mute`/`.pin`ケース参照)。
    var title: String {
        switch self {
        case .reply: String(localized: "返信")
        case .forward: String(localized: "転送")
        case .search: String(localized: "検索")
        case .info: String(localized: "情報")
        case .summarize: String(localized: "要約")
        case .translate: String(localized: "翻訳")
        case .mute: String(localized: "ミュート")
        case .pin: String(localized: "ピン留め")
        case .markUnread: String(localized: "未読にする")
        case .archive: String(localized: "アーカイブ")
        case .junk: String(localized: "迷惑メールにする")
        case .delete: String(localized: "削除")
        case .viewSource: String(localized: "ソースを表示")
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
        // ミュート中/ピン留め中の実際のアイコンは`title`のdoc comment
        // どおり状態依存 — ここでは設定画面用の既定 (非ミュート/非ピン留め
        // を意味する側) を返す。
        case .mute: "bell.slash"
        case .pin: "pin"
        case .markUnread: "envelope.badge"
        case .archive: "archivebox"
        case .junk: "exclamationmark.octagon"
        case .delete: "trash"
        case .viewSource: "doc.plaintext"
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
///
/// **2026-07-29 追加仕様での後方互換**: 「その他」ネイティブ項目を
/// `MessageToolbarAction`へ昇格した際、`defaultItems`の新規7件は
/// **非可視**をデフォルトにしている (`MessageToolbarPreferencesCoding
/// .parse`が「保存済みデータに無い id は、その id の`defaults`エントリ
/// 自身の可視性で補う」という仕様になっている — 単純に「無ければ可視」
/// ではない、そのdoc comment参照)。これにより、この変更以前から保存済み
/// の並びを持つユーザーはこの7件が「その他」に入ったまま (今までどおり)
/// upgrade でき、新規ユーザーの既定構成 (返信/転送/検索/情報/要約/翻訳が
/// ツールバー直接、残り7件+ショートカットは「その他」) とも一致する。
///
/// **Task #103 (「ソースを表示」)**: 同じ仕組みに乗った8件目の非可視デフォルト
/// 追加 — `.viewSource`は`defaultOrder`の`more`直前に足しただけで、
/// `defaultVisibleActions`には入れていない。上と全く同じ理屈 (`parse`の
/// 「無ければ可視」ではなく「その`defaults`エントリ自身の可視性」規則) で、
/// 既存ユーザー・新規ユーザーどちらでも自動的に「その他」入りで現れる —
/// 保存済みデータのマイグレーションは一切不要。
enum MessageToolbarSettingsStore {
    static let orderKey = "messageToolbar.order"

    /// Task #113 (2) (実機フィードバック「ボタンのラベルを表示」トグル):
    /// off にすると`MessageDetailFooterToolbar`のツールバーアイコンが
    /// アイコンのみになる (`Text`自体を出さず、`MessageToolbarIconLayout
    /// .iconLabelSpacing`で高さも詰める)。他の単純な on/off 設定と同じ
    /// 「素の`UserDefaults`キー、複雑なロジックは無し」方針 — 新規キーで
    /// 旧形式からの移行も不要 (`orderKey`のような後方互換の話が無い)。
    /// 既定は ON: 既存ユーザーの見た目を変えない。
    static let showsLabelsKey = "messageToolbar.showsLabels"
    static let defaultShowsLabels = true

    // Task #88: 要約/翻訳は「返信/転送/検索/情報」という既存メッセージ操作
    // 群のすぐ後ろに置く — フローティング時代の見た目の並び (要約が上、
    // 翻訳がその下) をそのまま左→右の順序に対応させた。2026-07-29:
    // 昇格した7件はその後ろ、「その他」の手前に追加した — 元々「その他」
    // メニュー内で並んでいた順番 (`MessageDetailFooterToolbar
    // .moreMenuButton`の旧実装) をそのまま踏襲している。
    static let defaultOrder: [MessageToolbarAction] = [
        .reply, .forward, .search, .info, .summarize, .translate,
        .mute, .pin, .markUnread, .archive, .junk, .delete,
        .viewSource,
        .more
    ]

    /// `defaultOrder`のうち、新規ユーザー (このキー未設定) でツールバーに
    /// 直接表示される既定集合。残り (`more`を除く) は「その他」入り —
    /// 昇格前の実機での見た目 (この6つだけがツールバー直接表示) を
    /// そのまま既定値として維持する。
    private static let defaultVisibleActions: Set<MessageToolbarAction> = [
        .reply, .forward, .search, .info, .summarize, .translate, .more
    ]

    /// 非表示にできず・並び替えもできず・常に末尾固定の唯一のアクション。
    private static let pinnedTrailingAction = MessageToolbarAction.more

    private static var defaults: [MessageToolbarItemPreference] { encode(defaultItems) }

    static var defaultItems: [MessageToolbarItemSetting] {
        defaultOrder.map { MessageToolbarItemSetting(action: $0, isVisible: defaultVisibleActions.contains($0)) }
    }

    /// 保存された並び順 + 可視性を読む。キーが未設定、旧形式、または保存後に
    /// アクション集合が変わった (このバージョンアップで新しいアクションが
    /// 増えた等) 場合でもクラッシュせず安全に解決する
    /// (`MessageToolbarPreferencesCoding.parse`の不変条件)。
    static func loadItems() -> [MessageToolbarItemSetting] {
        items(fromRawValue: UserDefaults.standard.string(forKey: orderKey))
    }

    /// `loadItems()`の中身 — 生の`UserDefaults`文字列を明示的に受け取る
    /// オーバーロード。`MessageDetailFooterToolbar`が`@AppStorage`
    /// (`UserDefaults`変更を購読し、書き込まれた瞬間に再描画を起こす仕組み)
    /// 経由で読んだ生文字列をここに渡せるようにするため切り出した —
    /// `UserDefaults.standard.string(forKey:)`を直接呼ぶだけの
    /// `loadItems()`はビュー内で使うと「設定画面を開いたまま裏でトグルして
    /// も、このビュー自身が変更を購読していないので戻ってくるまで反映され
    /// ない」という実機報告済みの不具合を再現してしまう。
    static func items(fromRawValue raw: String?) -> [MessageToolbarItemSetting] {
        let preferences = MessageToolbarPreferencesCoding.parse(
            raw: raw,
            defaults: defaults,
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
        MessageToolbarPreferencesCoding.encode(encode(items), defaults: defaults, pinnedTrailingID: pinnedTrailingAction.rawValue)
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
