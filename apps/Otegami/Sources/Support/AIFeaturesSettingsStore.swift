import Foundation

/// I「設定画面の再構成」→「メールビューア」節の「AI 機能の on/off (翻訳・要約を
/// まとめて)」— one master switch for both `TranslationFloatingButton` and
/// `AISummaryFloatingButton` (`MessageView`, Task #55 — floating buttons,
/// not the full-width bars these were originally named after). Default
/// **on**. Turning this off hides both buttons entirely (and skips the
/// auto-translate-on-open behavior
/// `TranslationSettingsStore.autoTranslateEnglishKey` would otherwise
/// trigger) regardless of that finer-grained setting's own value — this is
/// the "is AI involved at all" master switch; `autoTranslateEnglishKey`
/// remains the "given AI is on, should translation start automatically"
/// sub-setting, unchanged and still independently configurable in the same
/// "メールビューア" settings screen.
enum AIFeaturesSettingsStore {
    static let enabledKey = "aiFeatures.enabled"
    static let defaultEnabled = true
}
