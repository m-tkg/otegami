import Foundation
import Testing
@testable import OtegamiTranslation

/// Task #153 (スレッド全体のAI要約): covers `TranslationService.summarizeThread`'s
/// map-reduce shape, mirroring `TranslationServiceSummarizeLongTextTests`
/// (`summarizeLongText`'s own equivalent test) but asserting against
/// `FakeTranslationService.summarizeThreadDigestCallCount` (the ■経緯/■現状
/// reduce step) instead of `summarizeCallCount` (the single-message
/// ■要約/■伝えたいこと/■アクション reduce step) — the two map-reduce
/// pipelines share the same `summarizePlain` map step but reduce through
/// different structured calls, so they need independent call counters and
/// independent tests.
@Suite("TranslationService.summarizeThread")
struct TranslationServiceSummarizeThreadTests {
    @Test("short input (below the chunk threshold) calls summarizeThreadDigest exactly once and never summarizePlain")
    func shortInputSkipsChunking() async throws {
        let service = FakeTranslationService()
        let text = "[2026/07/27 10:00] 田中: 来週の定例会議の日程はいかがでしょうか。"
        _ = try await service.summarizeThread(text, targetLanguage: .japanese)
        #expect(await service.summarizeThreadDigestCallCount == 1)
        #expect(await service.summarizePlainCallCount == 0)
    }

    @Test("long input calls summarizePlain once per chunk, then summarizeThreadDigest exactly once for the final structured pass")
    func longInputMapsThenReducesOnce() async throws {
        let service = FakeTranslationService()
        // Long enough to guarantee multiple `TranslationChunker` chunks
        // (chunker splits at `defaultMaxChunkLength` == 2000 characters,
        // preferring sentence/line boundaries) — shaped as repeated
        // "[date] sender: text" lines, matching `ThreadDetailView`'s actual
        // thread-digest input format.
        let line = "[2026/07/27 10:00] 田中: これは長いスレッドの1メッセージです。"
        let longText = Array(repeating: line, count: 200).joined(separator: "\n") // well over 2,000 chars
        #expect(longText.count > TranslationChunker.defaultMaxChunkLength)

        _ = try await service.summarizeThread(longText, targetLanguage: .japanese)

        let plainCalls = await service.summarizePlainCallCount
        let digestCalls = await service.summarizeThreadDigestCallCount
        #expect(plainCalls > 1) // multiple chunks were mapped...
        #expect(digestCalls == 1) // ...and reduced through exactly one structured pass.
        // Independent counters: `summarizeThread` never touches the
        // single-message reduce step.
        #expect(await service.summarizeCallCount == 0)
    }
}
