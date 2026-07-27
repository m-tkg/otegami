import Foundation

/// A9-2 「常にテキストで表示」: when on, every HTML message defaults to its
/// extracted-text rendering (`text/plain` part if the message has one,
/// otherwise `HTMLTextExtractor`'s output) instead of the `WKWebView`-based
/// `HTMLMessageView`. `MessageView`'s per-message toggle button (next to the
/// `HTMLBadge`) can still flip an individual message back to HTML for that
/// viewing — this setting only decides the *default* each newly opened
/// message starts from. iOS/macOS common; plain `UserDefaults` key read
/// directly via `@AppStorage`, same reasoning as every other single-flag
/// preference in this directory (`ListDisplaySettingsStore` etc.'s doc
/// comments).
///
/// Default **off**: this app already renders HTML messages reasonably
/// (JS disabled, external/embedded images gated by their own settings —
/// `ImageSettingsStore`), so defaulting to text-only would throw away
/// legitimate formatting (tables, emphasis, structured newsletters) most
/// users would rather keep seeing unless they explicitly ask not to.
enum HTMLDisplaySettingsStore {
    static let alwaysShowPlainTextKey = "htmlDisplay.alwaysShowPlainText"
    static let defaultAlwaysShowPlainText = false

    /// Task #45「ダークモードで文字が読めない」— HTML メール自身が
    /// ライト前提 (白背景 + 濃色文字を明示指定) で書かれ、かつ自前のダーク
    /// モード対応 (`meta name="color-scheme"` / `prefers-color-scheme` を
    /// 含む `<style>`) を持たない場合に、アプリがダークモード表示中なら
    /// 本文を古典的な「反転」手法 (`filter: invert(1) hue-rotate(180deg)`
    /// を本文全体に適用し、`img`/`picture`/`video`/背景画像を持つ要素に
    /// 同フィルタを再適用して元の色を維持する — NetNewsWire 等で使われる
    /// 手法) で読めるようにするかどうか。既定 **ON**: 何もしなければ暗地に
    /// 暗文字でほぼ読めなくなるメールが実機で確認されており、大多数の
    /// メールでは反転の方が明らかに改善になる。
    ///
    /// `ImageSettingsStore`の2キーと同じ理由で、`HTMLMessageView.init`が
    /// `UserDefaults.standard.bool(forKey:)`を直接読んで`@State`を種付け
    /// する (`@AppStorage`ではない) — この設定は`HTMLDocumentBuilder.wrap
    /// (bodyHTML:autoAdjustColorsInDarkMode:)`が生成する HTML 文書そのもの
    /// に焼き込まれるため、メールを開くたびに新しく作られる
    /// `HTMLMessageView`インスタンスが常に最新の設定値を反映する必要が
    /// ある。`registerOtegamiHTMLDisplayDefaults()`が `AppEnvironment.init()`
    /// から起動時に一度呼ばれ、未設定キーでもこの既定値 (true) に解決
    /// されるようにしてある。
    static let autoAdjustColorsInDarkModeKey = "htmlDisplay.autoAdjustColorsInDarkMode"
    static let defaultAutoAdjustColorsInDarkMode = true
}

extension UserDefaults {
    /// `ImageSettingsStore.registerOtegamiImageDefaults()`と同じ理由 —
    /// `autoAdjustColorsInDarkModeKey`は`HTMLMessageView.init`が
    /// `UserDefaults.standard.bool(forKey:)`を直接読むため、`@AppStorage`の
    /// 「初回読み取り時だけ default 引数が効く」という挙動に頼れない。
    static func registerOtegamiHTMLDisplayDefaults() {
        standard.register(defaults: [
            HTMLDisplaySettingsStore.autoAdjustColorsInDarkModeKey: HTMLDisplaySettingsStore.defaultAutoAdjustColorsInDarkMode
        ])
    }
}
