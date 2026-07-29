import Foundation
import Testing
@testable import OtegamiTranslation

/// Task #153 (スレッド全体のAI要約) → Task #160 (実機フィードバック「経緯が
/// 短すぎる/内容が変」、map段をメッセージ単位に固定): covers
/// `TranslationService.summarizeThread(_:targetLanguage:onProgress:)`'s
/// per-message map-reduce shape — unlike the pre-#160 version (which mapped
/// over character-count-based `TranslationChunker` chunks of one big joined
/// string, calling `summarizePlain` zero times for a short thread), this
/// method now calls `summarizePlain` exactly once per input
/// `ThreadDigestMessage`, regardless of how short the thread is, then
/// reduces through exactly one `summarizeThreadDigest` call.
@Suite("TranslationService.summarizeThread")
struct TranslationServiceSummarizeThreadTests {
    @Test("calls summarizePlain exactly once per message, then summarizeThreadDigest exactly once")
    func mapsPerMessageThenReducesOnce() async throws {
        let service = FakeTranslationService()
        let messages = [
            ThreadDigestMessage(header: "[2026/07/27 10:00] 田中:", text: "来週の定例会議の日程はいかがでしょうか。"),
            ThreadDigestMessage(header: "[2026/07/27 11:00] 鈴木:", text: "水曜14時でいかがでしょうか。"),
            ThreadDigestMessage(header: "[2026/07/27 12:00] 田中:", text: "水曜14時で問題ありません。"),
        ]

        _ = try await service.summarizeThread(messages, targetLanguage: .japanese)

        #expect(await service.summarizePlainCallCount == messages.count)
        #expect(await service.summarizeThreadDigestCallCount == 1)
        // Independent counters: `summarizeThread` never touches the
        // single-message reduce step (`summarize`/`summarizeCallCount`).
        #expect(await service.summarizeCallCount == 0)
    }

    @Test("empty input short-circuits to an empty string without calling either step")
    func emptyInputSkipsEntirely() async throws {
        let service = FakeTranslationService()
        let result = try await service.summarizeThread([], targetLanguage: .japanese)
        #expect(result.isEmpty)
        #expect(await service.summarizePlainCallCount == 0)
        #expect(await service.summarizeThreadDigestCallCount == 0)
    }

    @Test("a single oversized message's text is chunked through summarizePlain before the final per-message compaction")
    func oversizedSingleMessageChunksBeforeCompacting() async throws {
        let service = FakeTranslationService()
        // Long enough to guarantee multiple `TranslationChunker` chunks for
        // this one message's own text alone (chunker splits at
        // `defaultMaxChunkLength` == 2000 characters).
        let longText = Array(repeating: "これは長い1通のメッセージの一部です。", count: 110).joined(separator: "\n")
        #expect(longText.count > TranslationChunker.defaultMaxChunkLength)

        let messages = [ThreadDigestMessage(header: "[2026/07/27 10:00] 田中:", text: longText)]
        _ = try await service.summarizeThread(messages, targetLanguage: .japanese)

        // The chunked safety net calls `summarizePlain` once per chunk, then
        // once more on the joined partials — always more than the 1-call-
        // per-message baseline `mapsPerMessageThenReducesOnce` asserts.
        #expect(await service.summarizePlainCallCount > 1)
        #expect(await service.summarizeThreadDigestCallCount == 1)
    }

    @Test("onProgress reports (1, n) through (n, n), once per message, in order")
    func reportsProgressPerMessage() async throws {
        let service = FakeTranslationService()
        let messages = (1...4).map { ThreadDigestMessage(header: "[2026/07/27 10:0\($0)] 田中:", text: "メッセージ\($0)") }

        actor ProgressRecorder {
            private(set) var events: [[Int]] = []
            func record(_ current: Int, _ total: Int) { events.append([current, total]) }
        }
        let recorder = ProgressRecorder()

        _ = try await service.summarizeThread(messages, targetLanguage: .japanese) { current, total in
            Task { await recorder.record(current, total) }
        }

        // Give the detached recording `Task`s a chance to land before
        // asserting — `onProgress` itself is synchronous from
        // `summarizeThread`'s point of view, so by the time it returns every
        // progress call has already been made (just possibly not yet
        // recorded by the actor).
        try await Task.sleep(nanoseconds: 50_000_000)
        let events = await recorder.events
        #expect(events.count == messages.count)
        #expect(events == [[1, 4], [2, 4], [3, 4], [4, 4]])
    }
}
