import Foundation
import Testing
@testable import OtegamiTranslation

/// Task #153 (スレッド全体のAI要約) → Task #160 (map段をメッセージ単位に
/// 固定) → Task #160フォローアップ (二重圧縮の根治) → Task #160フォロー
/// アップ2〜4 (メタ言及調の除去、仕上げパスの追加、■現状のハルシネーション
/// 対策) → **Task #160フォローアップ5 (ユーザー指示「スレッド要約の最終形
/// への簡素化」、現行の設計)**: covers `TranslationService.summarizeThread
/// (_:targetLanguage:onProgress:)`'s current, single-stage pipeline — map
/// (`summarizeThreadEntry`, fact-extraction, exactly once per message, via
/// `extractThreadEntryText`'s chunk safety net for an oversized single
/// message) and nothing else. No reduce/refine step, no `■経緯`/`■現状`
/// labels — the result is just each message's `"\(header) \(extracted)"`
/// line, joined with a blank line between messages.
/// `summarizePlain`/`summarize` (the single-message compression path) are
/// never touched by any of this — compression and fact-extraction are
/// separate protocol methods with separate call counters.
@Suite("TranslationService.summarizeThread")
struct TranslationServiceSummarizeThreadTests {
    @Test("calls summarizeThreadEntry exactly once per message, never summarizePlain/summarize")
    func mapsPerMessageOnly() async throws {
        let service = FakeTranslationService()
        let messages = [
            ThreadDigestMessage(header: "[7/27] 田中:", text: "来週の定例会議の日程はいかがでしょうか。"),
            ThreadDigestMessage(header: "[7/27] 鈴木:", text: "水曜14時でいかがでしょうか。"),
            ThreadDigestMessage(header: "[7/27] 田中:", text: "水曜14時で問題ありません。"),
        ]

        _ = try await service.summarizeThread(messages, targetLanguage: .japanese)

        #expect(await service.summarizeThreadEntryCallCount == messages.count)
        // The whole point of this redesign: the only model call is
        // fact-extraction (`summarizeThreadEntry`), never the compression
        // methods (`summarizePlain`/`summarize`) a single-message summary
        // uses, and never a second (reduce/refine) pass over the results.
        #expect(await service.summarizePlainCallCount == 0)
        #expect(await service.summarizeCallCount == 0)
    }

    @Test("joins each message's own extracted line with a blank line between, no labels")
    func joinsPerMessageLinesWithBlankLineBetween() async throws {
        let service = FakeTranslationService()
        let messages = [
            ThreadDigestMessage(header: "[7/27] 田中:", text: "来週の定例会議の日程はいかがでしょうか。"),
            ThreadDigestMessage(header: "[7/27] 鈴木:", text: "水曜14時でいかがでしょうか。"),
            ThreadDigestMessage(header: "[7/27] 田中:", text: "水曜14時で問題ありません。"),
        ]

        let result = try await service.summarizeThread(messages, targetLanguage: .japanese)

        // `FakeTranslationService.summarizeThreadEntry` is a deterministic
        // "first 5 sentences, then tag with the target language" transform
        // — each fixture message here is exactly one sentence, so the
        // transform is the identity function plus the `"[ja] "` tag.
        let expectedLine1 = "[7/27] 田中: [ja] 来週の定例会議の日程はいかがでしょうか。"
        let expectedLine2 = "[7/27] 鈴木: [ja] 水曜14時でいかがでしょうか。"
        let expectedLine3 = "[7/27] 田中: [ja] 水曜14時で問題ありません。"
        // A blank line (i.e. `"\n\n"`) between each message's line — no
        // `■経緯`/`■現状` label anywhere, no reduce/refine-step text.
        #expect(result == "\(expectedLine1)\n\n\(expectedLine2)\n\n\(expectedLine3)")
        #expect(!result.contains("■"))
    }

    @Test("empty input short-circuits to an empty string without calling summarizeThreadEntry")
    func emptyInputSkipsEntirely() async throws {
        let service = FakeTranslationService()
        let result = try await service.summarizeThread([], targetLanguage: .japanese)
        #expect(result.isEmpty)
        #expect(await service.summarizeThreadEntryCallCount == 0)
    }

    @Test("a single-message thread is just that one message's own line — no blank-line joining artifact")
    func singleMessageThreadIsJustThatLine() async throws {
        let service = FakeTranslationService()
        let messages = [ThreadDigestMessage(header: "[7/27] 田中:", text: "了解しました。")]

        let result = try await service.summarizeThread(messages, targetLanguage: .japanese)

        #expect(result == "[7/27] 田中: [ja] 了解しました。")
        #expect(await service.summarizeThreadEntryCallCount == 1)
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
        #expect(events == [[1, 4], [2, 4], [3, 4], [4, 4]])
    }
}
