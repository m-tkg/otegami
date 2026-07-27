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

    /// Task #45「ダークモードで文字が読めない」→ Task #51 で判定方式を
    /// 変更: HTML メール自身が自前のダークモード対応 (`meta
    /// name="color-scheme"` / `prefers-color-scheme` を含む `<style>`) を
    /// 持たない場合に、アプリがダークモード表示中なら本文を古典的な
    /// 「反転」手法 (`filter: invert(1) hue-rotate(180deg)` を本文全体に
    /// 適用し、`img`/`picture`/`video`/背景画像を持つ要素に同フィルタを
    /// 再適用して元の色を維持する — NetNewsWire 等で使われる手法) で
    /// 読めるようにするかどうか。この設定が ON でも、実際に反転が適用
    /// されるのは `HTMLWebViewCoordinator.fitToWidthScript` が読み込み後に
    /// 実効背景色を実測し、明るい (＝ライト前提) と判定できた場合のみ
    /// — 色指定を一切持たないメールのように、反転すると逆に読めなくなる
    /// ケースを Task #51 で除外した (`docs/design-system.md` の Task #51
    /// 節参照)。既定 **ON**: 何もしなければ暗地に暗文字でほぼ読めなく
    /// なるメールが実機で確認されており、大多数のライト専用メールでは
    /// 反転の方が明らかに改善になる。
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
