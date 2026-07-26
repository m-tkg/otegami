import Foundation

/// 1l "翻訳" settings block: "英文を自動で翻訳" (default **ON**) and "一覧に要約を
/// 出す" (default **OFF**) — persisted the same plain-`UserDefaults` way as
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
    /// require an explicit tap. Default **on** — matches the handoff's 1l
    /// default and this task's own guidance to make a deliberate call
    /// rather than leave it unspecified; on-device translation is fast
    /// enough (docs/translation.md's "実測で数秒〜") that defaulting to
    /// automatic favors the common case (a user opening an English email
    /// almost always wants the Japanese reading), with the toggle here as
    /// the escape hatch for anyone who'd rather not spend the latency/
    /// battery on messages they don't end up reading translated.
    static let autoTranslateEnglishKey = "translation.autoTranslateEnglish"
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
            TranslationSettingsStore.autoTranslateEnglishKey: true,
            TranslationSettingsStore.showListSummaryKey: false
        ])
    }
}
