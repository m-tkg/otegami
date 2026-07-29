import Testing
@testable import OtegamiTranslation

/// Task #159: `HybridTranslationService` is pure composition (no Apple-only
/// dependency), so it's fully testable here with two independent
/// `FakeTranslationService` instances standing in for the real
/// `AppleTranslationService` (translate) / `FoundationModelsTranslationService`
/// (summarize) pair `AppEnvironment` actually wires up — these tests exist to
/// pin down "translate calls only ever reach the translation engine, summarize
/// calls only ever reach the summarization engine, `availability` reflects the
/// translation engine specifically", none of which the real engines' own test
/// suites (`OtegamiTranslationFoundationModelsTests`, gated on real device
/// availability) can verify in CI.
@Suite("HybridTranslationService")
struct HybridTranslationServiceTests {
    @Test("translate delegates to the translation engine, never the summarization engine")
    func translateUsesTranslationEngine() async throws {
        let translationEngine = FakeTranslationService()
        let summarizationEngine = FakeTranslationService(behavior: .failure(message: "summarization engine must not be called for translate"))
        let hybrid = HybridTranslationService(translationEngine: translationEngine, summarizationEngine: summarizationEngine)

        let result = try await hybrid.translate("Hello", from: .english, to: .japanese)
        #expect(result == "[ja] Hello")
        let translateCount = await translationEngine.translateCallCount
        #expect(translateCount == 1)
    }

    @Test("translateParagraphs delegates to the translation engine")
    func translateParagraphsUsesTranslationEngine() async throws {
        let translationEngine = FakeTranslationService()
        let summarizationEngine = FakeTranslationService(behavior: .failure(message: "summarization engine must not be called"))
        let hybrid = HybridTranslationService(translationEngine: translationEngine, summarizationEngine: summarizationEngine)

        let results = try await hybrid.translateParagraphs(["A.", "B."], from: .english, to: .japanese)
        #expect(results == ["[ja] A.", "[ja] B."])
    }

    @Test("summarize/summarizePlain/summarizeThreadDigest delegate to the summarization engine, never the translation engine")
    func summarizeUsesSummarizationEngine() async throws {
        let translationEngine = FakeTranslationService(behavior: .failure(message: "translation engine must not be called for summarize"))
        let summarizationEngine = FakeTranslationService()
        let hybrid = HybridTranslationService(translationEngine: translationEngine, summarizationEngine: summarizationEngine)

        _ = try await hybrid.summarize("One. Two. Three.", targetLanguage: .japanese, sentenceCount: 2)
        _ = try await hybrid.summarizePlain("One. Two.", targetLanguage: .japanese, sentenceCount: 1)
        _ = try await hybrid.summarizeThreadDigest("Some thread text.", targetLanguage: .japanese)

        let summarizeCount = await summarizationEngine.summarizeCallCount
        let summarizePlainCount = await summarizationEngine.summarizePlainCallCount
        let summarizeThreadDigestCount = await summarizationEngine.summarizeThreadDigestCallCount
        #expect(summarizeCount == 1)
        #expect(summarizePlainCount == 1)
        #expect(summarizeThreadDigestCount == 1)
    }

    @Test("availability reflects the translation engine, not the summarization engine")
    func availabilityReflectsTranslationEngine() {
        let translationEngine = FakeTranslationService(availability: .available)
        let summarizationEngine = FakeTranslationService(availability: .unavailable(reason: .modelNotReady))
        let hybrid = HybridTranslationService(translationEngine: translationEngine, summarizationEngine: summarizationEngine)

        #expect(hybrid.availability == .available)
    }
}
