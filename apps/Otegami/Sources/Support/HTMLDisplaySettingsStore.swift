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
}
