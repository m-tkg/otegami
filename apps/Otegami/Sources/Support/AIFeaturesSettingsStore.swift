import Foundation

/// I「設定画面の再構成」→「メールビューア」節の「AI 機能の on/off (翻訳・要約を
/// まとめて)」— one master switch for both the 要約 and 翻訳 icons in
/// `MessageDetailFooterToolbar` (`MessageView`'s `syncAIFeaturesState()`
/// reads this via `aiFeaturesEnabled`; originally Task #55's floating
/// buttons, moved into the footer toolbar by Task #88 — see
/// `MessageDetailFooterToolbar`'s doc comment). Default **on**. Turning this
/// off skips the auto-translate-on-open behavior
/// `TranslationSettingsStore.autoTranslateEnglishKey` would otherwise
/// trigger, regardless of that finer-grained setting's own value — this is
/// the "is AI involved at all" master switch. Since Task #88, turning it off
/// no longer *hides* the two icons (指示どおり、並びの安定のため常に表示) —
/// it grays them out instead, same as any other reason they're currently
/// unusable (`MessageToolbarAction`'s doc comment). `autoTranslateEnglishKey`
/// remains the "given AI is on, should translation start automatically"
/// sub-setting, unchanged and still independently configurable in the same
/// "メールビューア" settings screen.
enum AIFeaturesSettingsStore {
    static let enabledKey = "aiFeatures.enabled"
    static let defaultEnabled = true
}
