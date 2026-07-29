import Foundation

/// Task #159 (メール翻訳を Apple Translation フレームワークの専用 NMT へ切替、
/// 要約は Foundation Models のまま): recombines a translate-only engine
/// (`TranslationOnlyService` — in practice `OtegamiTranslationApple`'s
/// `AppleTranslationService`, backed by `Translation.TranslationSession`)
/// with a full `TranslationService` used only for its summarize methods (in
/// practice `FoundationModelsTranslationService`) into a single
/// `TranslationService` — the shape every existing caller
/// (`MessageTranslator`, `MessageView.requestSummary`/`kickoffTranslationIfNeeded`,
/// `ThreadDetailView.requestThreadSummary`) already expects, so none of them
/// needed to change for this engine swap.
///
/// Deliberately holds `summarizationEngine` as `any TranslationService` (not
/// the concrete `FoundationModelsTranslationService` type) even though only
/// its summarize methods are ever called here — keeps this type testable
/// with two independent `FakeTranslationService` instances
/// (`HybridTranslationServiceTests`) without any Apple-only dependency, the
/// same reason `MessageTranslator` itself takes `any TranslationService`
/// rather than a concrete engine.
///
/// `availability` forwards `translationEngine`'s, not
/// `summarizationEngine`'s — `AppEnvironment.isTranslationAvailable` (what
/// gates the translate button) reads this property, and Task #159's own
/// spec ("翻訳ボタンは常時有効の現仕様維持") wants that gated on the
/// translation engine specifically. Summarization's own availability is a
/// separate concern `AppEnvironment.isSummarizationAvailable` answers by
/// asking `FoundationModelsTranslationService` directly, not through this
/// type at all — see that property's doc comment.
public struct HybridTranslationService: TranslationService {
    private let translationEngine: any TranslationOnlyService
    private let summarizationEngine: any TranslationService

    public init(translationEngine: any TranslationOnlyService, summarizationEngine: any TranslationService) {
        self.translationEngine = translationEngine
        self.summarizationEngine = summarizationEngine
    }

    public var availability: TranslationAvailability { translationEngine.availability }

    public func translate(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) async throws -> String {
        try await translationEngine.translate(text, from: source, to: target)
    }

    public func translateParagraphs(_ paragraphs: [String], from source: TranslationLanguage, to target: TranslationLanguage) async throws -> [String] {
        try await translationEngine.translateParagraphs(paragraphs, from: source, to: target)
    }

    public func translateStream(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) -> AsyncThrowingStream<String, Error> {
        translationEngine.translateStream(text, from: source, to: target)
    }

    public func summarize(_ text: String, targetLanguage: TranslationLanguage, sentenceCount: Int) async throws -> String {
        try await summarizationEngine.summarize(text, targetLanguage: targetLanguage, sentenceCount: sentenceCount)
    }

    public func summarizePlain(_ text: String, targetLanguage: TranslationLanguage, sentenceCount: Int) async throws -> String {
        try await summarizationEngine.summarizePlain(text, targetLanguage: targetLanguage, sentenceCount: sentenceCount)
    }

    /// Task #160フォローアップ (二重圧縮の根治): `summarize`/`summarizePlain`
    /// と同じ理由でそのまま`summarizationEngine`へ委譲する — 要約系はすべて
    /// `FoundationModelsTranslationService`のまま (Task #159)。
    public func summarizeThreadEntry(_ text: String, targetLanguage: TranslationLanguage) async throws -> String {
        try await summarizationEngine.summarizeThreadEntry(text, targetLanguage: targetLanguage)
    }
}
