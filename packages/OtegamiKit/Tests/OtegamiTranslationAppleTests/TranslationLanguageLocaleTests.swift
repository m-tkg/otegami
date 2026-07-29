import Testing
import Translation
@testable import OtegamiTranslation
@testable import OtegamiTranslationApple

/// Task #159: `AppleTranslationService`'s actual translate calls need a live
/// `TranslationSession`, which only exists once a hosting SwiftUI view has
/// run `.translationTask(_:action:)` — impossible to obtain in a plain
/// `swift test` process (mirrors why `OtegamiTranslationFoundationModelsTests`
/// gates its real-engine tests on `SystemLanguageModel.default.isAvailable`
/// rather than running unconditionally). This suite only covers the one pure,
/// synchronous piece of this target: `TranslationLanguage.locale`'s mapping —
/// see `docs/translation.md`'s Task #159 section for what's verified here vs.
/// left for a real device.
@Suite("TranslationLanguage+Locale")
struct TranslationLanguageLocaleTests {
    @Test("english maps to Locale.Language(languageCode: .english)")
    func englishMapsToEnglishLocale() {
        #expect(TranslationLanguage.english.locale == Locale.Language(languageCode: .english))
    }

    @Test("japanese maps to Locale.Language(languageCode: .japanese)")
    func japaneseMapsToJapaneseLocale() {
        #expect(TranslationLanguage.japanese.locale == Locale.Language(languageCode: .japanese))
    }
}
