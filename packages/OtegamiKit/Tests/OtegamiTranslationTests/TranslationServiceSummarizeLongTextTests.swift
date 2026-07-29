import Foundation
import Testing
@testable import OtegamiTranslation

/// Covers `TranslationService.summarizeLongText`'s map-reduce shape via
/// `FakeTranslationService`'s separate `summarizeCallCount`/
/// `summarizePlainCallCount` counters — Task #122's structural fix: the
/// per-chunk "map" pass must go through the unlabeled `summarizePlain`, and
/// the final, combined "reduce" pass must call the structured `summarize`
/// exactly once, whether the input split into one chunk or many. Before this
/// fix, `summarizeLongText` called the *structured* `summarize` once per
/// chunk and, for a single-chunk input, skipped the final structuring pass
/// entirely — see `TranslationService.summarizeLongText`'s doc comment for
/// the full "why" (a real-device report of repeated/leaked 3-part output).
@Suite("TranslationService.summarizeLongText")
struct TranslationServiceSummarizeLongTextTests {
    @Test("short input (below the chunk threshold) calls summarize exactly once and never summarizePlain")
    func shortInputSkipsChunking() async throws {
        let service = FakeTranslationService()
        let text = "A short email body well under the chunk threshold."
        _ = try await service.summarizeLongText(text, targetLanguage: .japanese)
        #expect(await service.summarizeCallCount == 1)
        #expect(await service.summarizePlainCallCount == 0)
    }

    @Test("long input calls summarizePlain once per chunk, then summarize exactly once for the final structured pass")
    func longInputMapsThenReducesOnce() async throws {
        let service = FakeTranslationService()
        // Long enough to guarantee multiple `TranslationChunker` chunks
        // (chunker splits at `defaultMaxChunkLength` == 2000 characters,
        // preferring sentence boundaries).
        let sentence = "This is one sentence in a very long email body. "
        let longText = String(repeating: sentence, count: 200) // ~9,800 chars
        #expect(longText.count > TranslationChunker.defaultMaxChunkLength)

        _ = try await service.summarizeLongText(longText, targetLanguage: .japanese)

        let plainCalls = await service.summarizePlainCallCount
        let structuredCalls = await service.summarizeCallCount
        #expect(plainCalls > 1) // multiple chunks were mapped...
        #expect(structuredCalls == 1) // ...and reduced through exactly one structured pass.
    }

    /// Task #122's fix removed a now-provably-dead `partialSummaries.count
    /// > 1` branch that used to skip the final structured pass and return
    /// the map step's raw output directly. It turns out that branch could
    /// never actually trigger: `summarizeLongText` only chunks when
    /// `text.count > TranslationChunker.defaultMaxChunkLength`, and
    /// `TranslationChunker.chunk` (using that same default `maxLength`) can
    /// only return a single chunk when the *whole* input already fits
    /// within `maxLength` — contradicting the guard that got it into the
    /// chunking branch at all. This test pins that invariant down directly
    /// (independent of `summarizeLongText`) so a future change to either
    /// threshold can't silently reintroduce a reachable single-chunk case
    /// without `summarizeLongText`'s unconditional final `summarize` call
    /// (verified by the two tests above) being revisited.
    @Test("TranslationChunker.chunk never returns exactly one chunk for input over its own maxLength")
    func chunkerNeverReturnsExactlyOneChunkWhenOverThreshold() {
        for length in [
            TranslationChunker.defaultMaxChunkLength + 1,
            TranslationChunker.defaultMaxChunkLength + 50,
            TranslationChunker.defaultMaxChunkLength * 3,
        ] {
            let longText = String(repeating: "a", count: length)
            let chunks = TranslationChunker.chunk(longText)
            #expect(chunks.count != 1, "length \(length) produced exactly one chunk")
        }
    }
}
