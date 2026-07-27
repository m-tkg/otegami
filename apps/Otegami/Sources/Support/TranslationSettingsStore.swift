import Foundation

/// 1l "翻訳" settings block: "英文を自動で翻訳" (default **OFF** — see
/// `autoTranslateEnglishKey`'s doc comment for why this flipped from the
/// handoff's original **ON**) and "一覧に要約を出す" (default **OFF**) —
/// persisted the same plain-`UserDefaults` way as
/// `CloudSyncSettingsStore`/`PushSettingsStore` (no secrets involved, and
/// both flags are read via `@AppStorage` at the view layer, not through this
/// struct directly — its role is just to name the keys/defaults in one
/// place other code, like `MessageView`'s translation bar, can reference
/// without repeating the raw string).
///
/// design-phase-3 scope note: `showListSummaryInList` is exposed in
/// Settings (1l explicitly lists it) but has **no reader yet** — showing a
/// translated snippet in `ThreadRowView`'s preview line would mean
/// triggering (and caching) a translation for every visible English row
/// just from scrolling the list, not only when a message is opened, which
/// is a meaningfully larger feature (a background translation trigger, plus
/// deciding when a list row's cache is "good enough" to render) than this
/// phase's scope. Documented here rather than silently doing nothing: the
/// toggle exists and persists correctly, list rendering doesn't consult it
/// yet. See `docs/design-system.md`'s design-phase-3 section.
enum TranslationSettingsStore {
    /// `MessageView`'s translation bar (1i): auto-translate on open vs.
    /// require an explicit tap.
    ///
    /// 実機フィードバック (「翻訳機能は、勝手に実行しないで欲しい」):
    /// default flipped from **on** (this project's original design-phase-3
    /// choice — on-device translation is fast enough, `docs/translation.md`'s
    /// "実測で数秒〜", that defaulting to automatic seemed to favor the
    /// common case) to **off**. In practice that meant *every* English
    /// message got silently translated the moment it was opened, with no
    /// way to see the original first — exactly the opposite of what was
    /// wanted. The translation bar itself is unchanged (it still appears
    /// for every English message whenever AI 機能 is on); it just no longer
    /// triggers itself — translation now only ever runs from an explicit
    /// tap on "翻訳" (or a user turning this setting back on by hand in
    /// 設定 → メールビューア → AI 機能).
    ///
    /// **Key renamed** (`.v2` suffix) rather than just flipping the
    /// registered default below: `UserDefaults.register(defaults:)` only
    /// supplies a fallback for a key that's never been explicitly written,
    /// and `@AppStorage` reading a key at least once can itself persist the
    /// resolved value back into `UserDefaults` — so a device that already
    /// opened the translation bar under the old default could keep reading
    /// back `true` forever no matter what this store now registers,
    /// silently defeating the new off-by-default intent for exactly the
    /// installs (existing users) where it matters. A new key side-steps
    /// this: no existing device has ever written a value for it, so
    /// `registerOtegamiTranslationDefaults()`'s `false` is what every
    /// reader sees — fresh install or upgrade alike.
    static let autoTranslateEnglishKey = "translation.autoTranslateEnglish.v2"
    /// `@AppStorage(autoTranslateEnglishKey) private var autoTranslateEnglish
    /// = TranslationSettingsStore.defaultAutoTranslateEnglish` at both call
    /// sites (`MessageView`/`MailViewerSettingsView`) — named here instead
    /// of each repeating a bare `false` literal, matching
    /// `ImageSettingsStore.defaultAutoShowEmbedded`'s/`HTMLDisplaySettingsStore
    /// .defaultAlwaysShowPlainText`'s existing pattern in this codebase.
    static let defaultAutoTranslateEnglish = false
    static let showListSummaryKey = "translation.showListSummaryInList"
}

extension UserDefaults {
    /// `@AppStorage`'s own default-value parameter only applies the first
    /// time a key is read *by that specific `@AppStorage` call site*; a
    /// fresh install registering these defaults once up front (the standard
    /// `UserDefaults.register(defaults:)` pattern) keeps every reader —
    /// `@AppStorage` in a view, or a plain `UserDefaults.standard.bool(forKey:)`
    /// elsewhere — agreeing on the same default without each needing to
    /// repeat it.
    static func registerOtegamiTranslationDefaults() {
        standard.register(defaults: [
            TranslationSettingsStore.autoTranslateEnglishKey: false,
            TranslationSettingsStore.showListSummaryKey: false
        ])
    }
}
