import Foundation

/// B「画像の設定」— two independent auto-display toggles for `HTMLMessageView`.
/// Read both via plain `UserDefaults`/`@AppStorage` (no `AppEnvironment`
/// involvement, same reasoning as every other single-flag preference in this
/// directory) *and* via `UserDefaults.standard.bool(forKey:)` directly from
/// `HTMLMessageView`'s `init` (to seed its `@State` — see that type's doc
/// comment for why a plain `@AppStorage` default doesn't work there), so
/// `registerOtegamiImageDefaults()` (called from `AppEnvironment.init()`,
/// mirroring `UserDefaults.registerOtegamiTranslationDefaults()`) matters
/// here in a way it doesn't for most of this directory's other stores: a
/// fresh install must have both keys resolve to their real defaults from the
/// very first `HTMLMessageView` construction, not just from the first
/// `@AppStorage`-backed read.
///
/// **This flips both defaults relative to the app's previous (M2-era)
/// behavior** — a deliberate, user-specified change, not a bug:
/// - Embedded images (cid: inline images / image attachments) used to
///   auto-show unconditionally; now they default **off**.
/// - Remote (`http`/`https`) images used to be blocked-by-default with a
///   manual "show images" banner; that banner stays (as the manual override
///   for when this setting is off), but the setting itself now defaults
///   **on**.
enum ImageSettingsStore {
    /// B5 「埋め込み画像を自動表示」(cid: インライン画像 / 画像添付) — default
    /// **off**. `HTMLMessageView`'s existing "画像を表示" banner pattern is
    /// reused for embedded images too (a distinct banner, since the two
    /// settings are independent) as the manual per-message override.
    static let autoShowEmbeddedImagesKey = "images.autoShowEmbedded"
    static let defaultAutoShowEmbedded = false

    /// B6 「リモート画像を自動で読み込む」— default **on**. Trades a small
    /// privacy exposure (a remote image request can tell the sender the
    /// message was opened — "開封トラッキング") for not having to tap
    /// through a banner on every external-image message; the Settings row
    /// for this carries an explicit note about that tradeoff
    /// (`AccountsListContent`), and the existing "画像を表示" banner still
    /// works as a per-message opt-in for anyone who turns this off.
    static let autoShowRemoteImagesKey = "images.autoShowRemote"
    static let defaultAutoShowRemote = true

    /// Task #207 (ユーザー要望「(平文httpの画像を)許可する方針でいいが、
    /// 『http の画像があるけどいい?』的な確認ダイアログは出してほしい」):
    /// `autoShowRemoteImagesKey`(B6、上記)とは独立した3値設定 — 平文
    /// `http`(`https`は対象外) の画像は経路上で改竄されうるため、`https`と
    /// 違い既定では読み込む前に確認する
    /// (`HTMLMessageView.shouldOfferPlaintextHTTPImages`)。
    /// `autoShowRemoteImagesKey`が false の間はこの設定自体が意味を持たない
    /// — そもそもリモート画像全部が既存の「画像を表示」バナーでブロック
    /// されており、平文httpだけを個別に扱う余地がない (`HTMLMessageView`
    /// のdoc comment参照)。既定は`.ask`(ユーザー要望「今回の要望の趣旨」
    /// どおり、確認するが既定)。
    static let plaintextHTTPImagePolicyKey = "images.plaintextHTTPImagePolicy"
    static let defaultPlaintextHTTPImagePolicy = PlaintextHTTPImagePolicy.ask
}

/// Task #207: `ImageSettingsStore.plaintextHTTPImagePolicyKey`の値の型 —
/// `MessagePostActionSettingsStore.PostDeleteArchiveAction`と同じ
/// 「`String, CaseIterable, Identifiable`のenumをそのまま`@AppStorage`の
/// rawValueとして使う」パターン。
enum PlaintextHTTPImagePolicy: String, CaseIterable, Identifiable {
    /// 既定 — メールを開くたびに確認ダイアログを出す
    /// (`HTMLMessageView.showPlaintextHTTPImagesAlert`)。
    case ask
    /// 確認せず常に読み込む (`https`の画像と同じ扱いになる)。
    case alwaysAllow
    /// 確認せず常にブロックしたまま (バナーも出さない — 「常に拒否」を
    /// 選んだ人に毎回バナーで催促し続けるのは趣旨に反するため)。
    case alwaysBlock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: String(localized: "確認する")
        case .alwaysAllow: String(localized: "常に許可")
        case .alwaysBlock: String(localized: "常に拒否")
        }
    }
}

extension UserDefaults {
    static func registerOtegamiImageDefaults() {
        standard.register(defaults: [
            ImageSettingsStore.autoShowEmbeddedImagesKey: ImageSettingsStore.defaultAutoShowEmbedded,
            ImageSettingsStore.autoShowRemoteImagesKey: ImageSettingsStore.defaultAutoShowRemote,
            ImageSettingsStore.plaintextHTTPImagePolicyKey: ImageSettingsStore.defaultPlaintextHTTPImagePolicy.rawValue
        ])
    }
}
