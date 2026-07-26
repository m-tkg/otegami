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
}

extension UserDefaults {
    static func registerOtegamiImageDefaults() {
        standard.register(defaults: [
            ImageSettingsStore.autoShowEmbeddedImagesKey: ImageSettingsStore.defaultAutoShowEmbedded,
            ImageSettingsStore.autoShowRemoteImagesKey: ImageSettingsStore.defaultAutoShowRemote
        ])
    }
}
