import Foundation
import Testing
@testable import OtegamiTranslation

/// Task #153 (スレッド全体のAI要約) → Task #160 (map段をメッセージ単位に
/// 固定) → Task #160フォローアップ (実機フィードバック「スレッド要約が
/// 雑すぎて内容がほとんど抜け落ちている」、二重圧縮の根治): covers
/// `TranslationService.summarizeThread(_:targetLanguage:onProgress:)`'s
/// redesigned shape — the map step now calls `summarizeThreadEntry`
/// (fact-extraction, not compression) exactly once per input
/// `ThreadDigestMessage`, and `■経緯` is assembled by this method itself
/// (never a model call) by joining `"\(header) \(extracted)"` lines in
/// order; only `■現状` goes through one `summarizeThreadDigest` call, fed
/// that same joined text. `summarizePlain`/`summarize` (the single-message
/// compression path) are never touched by this method at all — that's the
/// whole point of Task #160フォローアップ's redesign (compression and
/// fact-extraction are now separate protocol methods with separate call
/// counters).
@Suite("TranslationService.summarizeThread")
struct TranslationServiceSummarizeThreadTests {
    @Test("calls summarizeThreadEntry exactly once per message, then summarizeThreadDigest exactly once, never summarizePlain/summarize")
    func mapsPerMessageThenReducesOnce() async throws {
        let service = FakeTranslationService()
        let messages = [
            ThreadDigestMessage(header: "[7/27] 田中:", text: "来週の定例会議の日程はいかがでしょうか。"),
            ThreadDigestMessage(header: "[7/27] 鈴木:", text: "水曜14時でいかがでしょうか。"),
            ThreadDigestMessage(header: "[7/27] 田中:", text: "水曜14時で問題ありません。"),
        ]

        _ = try await service.summarizeThread(messages, targetLanguage: .japanese)

        #expect(await service.summarizeThreadEntryCallCount == messages.count)
        #expect(await service.summarizeThreadDigestCallCount == 1)
        // The whole point of this redesign: the map step is fact-extraction
        // (`summarizeThreadEntry`), never the compression methods
        // (`summarizePlain`/`summarize`) a single-message summary uses.
        #expect(await service.summarizePlainCallCount == 0)
        #expect(await service.summarizeCallCount == 0)
    }

    @Test("assembles ■経緯 as an app-built bullet list (no reduce-step model call for it), then ■現状 from summarizeThreadDigest")
    func assemblesProgressWithoutModelReduction() async throws {
        let service = FakeTranslationService()
        let messages = [
            ThreadDigestMessage(header: "[7/27] 田中:", text: "来週の定例会議の日程はいかがでしょうか。"),
            ThreadDigestMessage(header: "[7/27] 鈴木:", text: "水曜14時でいかがでしょうか。"),
        ]

        let result = try await service.summarizeThread(messages, targetLanguage: .japanese)

        // `FakeTranslationService.summarizeThreadEntry` is a deterministic
        // "first 5 sentences, then tag with the target language" transform
        // (same shape as `summarizePlain`'s "first N sentences") — each
        // fixture message here is exactly one sentence, so the transform is
        // the identity function plus the `"[ja] "` tag.
        let expectedLine1 = "[7/27] 田中: [ja] 来週の定例会議の日程はいかがでしょうか。"
        let expectedLine2 = "[7/27] 鈴木: [ja] 水曜14時でいかがでしょうか。"
        let expectedCombined = "\(expectedLine1)\n\(expectedLine2)"
        // `FakeTranslationService.summarizeThreadDigest` returns
        // `"■現状\n[ja] <its own input verbatim>"` — its input here is
        // exactly `expectedCombined` (the same joined text `■経緯` displays).
        let expectedCurrentStatus = "■現状\n[ja] \(expectedCombined)"
        let expected = "■経緯\n\(expectedCombined)\n\n\(expectedCurrentStatus)"

        #expect(result == expected)
    }

    @Test("empty input short-circuits to an empty string without calling either step")
    func emptyInputSkipsEntirely() async throws {
        let service = FakeTranslationService()
        let result = try await service.summarizeThread([], targetLanguage: .japanese)
        #expect(result.isEmpty)
        #expect(await service.summarizeThreadEntryCallCount == 0)
        #expect(await service.summarizeThreadDigestCallCount == 0)
    }

    @Test("a single oversized message's text is chunked through summarizeThreadEntry, one call per chunk and no extra recombination call")
    func oversizedSingleMessageChunksWithoutRecombining() async throws {
        let service = FakeTranslationService()
        // Long enough to guarantee multiple `TranslationChunker` chunks for
        // this one message's own text alone (chunker splits at
        // `defaultMaxChunkLength` == 2000 characters).
        let longText = Array(repeating: "これは長い1通のメッセージの一部です。", count: 110).joined(separator: "\n")
        #expect(longText.count > TranslationChunker.defaultMaxChunkLength)
        let chunkCount = TranslationChunker.chunk(longText).count
        #expect(chunkCount > 1)

        let messages = [ThreadDigestMessage(header: "[7/27] 田中:", text: longText)]
        _ = try await service.summarizeThread(messages, targetLanguage: .japanese)

        // Task #160フォローアップ: unlike the old chunked-compression safety
        // net (chunks summarized, then the joined partials summarized once
        // more), fact-extraction never re-runs a combining model call —
        // exactly `chunkCount` calls, not `chunkCount + 1`.
        #expect(await service.summarizeThreadEntryCallCount == chunkCount)
        #expect(await service.summarizeThreadDigestCallCount == 1)
    }

    @Test("onProgress reports (1, n) through (n, n), once per message, in order")
    func reportsProgressPerMessage() async throws {
        let service = FakeTranslationService()
        let messages = (1...4).map { ThreadDigestMessage(header: "[7/2\($0)] 田中:", text: "メッセージ\($0)") }

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
