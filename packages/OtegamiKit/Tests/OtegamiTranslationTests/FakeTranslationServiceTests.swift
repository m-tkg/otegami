import Testing
@testable import OtegamiTranslation

@Suite("FakeTranslationService")
struct FakeTranslationServiceTests {
    @Test("availability reflects the value it was constructed with")
    func availabilityReflectsConstruction() {
        let available = FakeTranslationService(availability: .available)
        #expect(available.availability == .available)

        let unavailable = FakeTranslationService(availability: .unavailable(reason: .modelNotReady))
        #expect(unavailable.availability == .unavailable(reason: .modelNotReady))
    }

    @Test("translate produces a deterministic, target-language-tagged result")
    func translateIsDeterministic() async throws {
        let service = FakeTranslationService()
        let result = try await service.translate("Hello", from: .english, to: .japanese)
        #expect(result == "[ja] Hello")

        // Same input, same output — no hidden state/randomness.
        let again = try await service.translate("Hello", from: .english, to: .japanese)
        #expect(again == result)
    }

    @Test("translateParagraphs preserves order and count")
    func translateParagraphsPreservesShape() async throws {
        let service = FakeTranslationService()
        let paragraphs = ["First paragraph.", "Second paragraph.", "Third."]
        let results = try await service.translateParagraphs(paragraphs, from: .english, to: .japanese)
        #expect(results == ["[ja] First paragraph.", "[ja] Second paragraph.", "[ja] Third."])
    }

    @Test("translateParagraphs on an empty list returns an empty list without engaging behavior")
    func translateParagraphsEmpty() async throws {
        let service = FakeTranslationService(behavior: .failure(message: "should never be reached"))
        let results = try await service.translateParagraphs([], from: .english, to: .japanese)
        #expect(results.isEmpty)
    }

    @Test("translate throws .failed when configured to fail")
    func translateFails() async throws {
        let service = FakeTranslationService(behavior: .failure(message: "boom"))
        await #expect(throws: TranslationServiceError.failed(message: "boom")) {
            try await service.translate("Hello", from: .english, to: .japanese)
        }
    }

    @Test("translate throws .unavailable when configured unavailable")
    func translateUnavailable() async throws {
        let service = FakeTranslationService(behavior: .unavailable(.appleIntelligenceNotEnabled))
        await #expect(throws: TranslationServiceError.unavailable(.appleIntelligenceNotEnabled)) {
            try await service.translate("Hello", from: .english, to: .japanese)
        }
    }

    @Test("configure(behavior:) changes subsequent calls without needing a new instance")
    func configureChangesBehavior() async throws {
        let service = FakeTranslationService()
        _ = try await service.translate("Hello", from: .english, to: .japanese)

        await service.configure(behavior: .failure(message: "now broken"))
        await #expect(throws: TranslationServiceError.failed(message: "now broken")) {
            try await service.translate("Hello", from: .english, to: .japanese)
        }
    }

    @Test("translateCallCount tracks how many translate() calls were made")
    func callCountTracks() async throws {
        let service = FakeTranslationService()
        #expect(await service.translateCallCount == 0)
        _ = try await service.translate("A", from: .english, to: .japanese)
        _ = try await service.translate("B", from: .english, to: .japanese)
        #expect(await service.translateCallCount == 2)
    }

    @Test("translateStream yields cumulative chunks ending at the full translation")
    func streamYieldsCumulativeChunks() async throws {
        let service = FakeTranslationService()
        var chunks: [String] = []
        for try await chunk in service.translateStream("one two three", from: .english, to: .japanese) {
            chunks.append(chunk)
        }
        #expect(chunks.last == "[ja] one two three")
        // Every chunk after the first is a strict extension of the one
        // before it — the "cumulative, not delta" contract every
        // TranslationService.translateStream conformer must honor.
        for (previous, current) in zip(chunks, chunks.dropFirst()) {
            #expect(current.hasPrefix(previous))
        }
    }

    @Test("translateStream throws when configured to fail")
    func streamFails() async throws {
        let service = FakeTranslationService(behavior: .failure(message: "stream broke"))
        await #expect(throws: TranslationServiceError.failed(message: "stream broke")) {
            for try await _ in service.translateStream("Hello", from: .english, to: .japanese) {}
        }
    }

    @Test("summarize picks the first N sentences, deterministically tagged")
    func summarizePicksFirstSentences() async throws {
        let service = FakeTranslationService()
        let text = "First sentence. Second sentence. Third sentence. Fourth sentence."
        let summary = try await service.summarize(text, targetLanguage: .japanese, sentenceCount: 2)
        #expect(summary == "[ja] First sentence. Second sentence.")
    }

    @Test("the default summarize(_:targetLanguage:) overload requests 2 sentences")
    func summarizeDefaultOverload() async throws {
        let service = FakeTranslationService()
        let text = "One. Two. Three."
        let summary = try await service.summarize(text, targetLanguage: .japanese)
        #expect(summary == "[ja] One. Two.")
    }
}
