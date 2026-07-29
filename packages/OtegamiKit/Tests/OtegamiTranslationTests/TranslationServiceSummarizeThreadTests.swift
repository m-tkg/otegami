import Foundation
import Testing
@testable import OtegamiTranslation

/// Task #153 (スレッド全体のAI要約) → Task #160 (map段をメッセージ単位に
/// 固定) → Task #160フォローアップ (二重圧縮の根治) → Task #160フォロー
/// アップ3 (ユーザー要望「要約済みのものを再度読ませてさらに要約を挟ませて
/// シンプルにする」): covers `TranslationService.summarizeThread(_:
/// targetLanguage:onProgress:)`'s full pipeline — map (`summarizeThreadEntry`,
/// fact-extraction, exactly once per message) → optional refine
/// (`refineThreadEntries`, condenses the per-message lines into `■経緯`,
/// skipped for `messages.count <= 3` and falling back to the raw per-message
/// list if it throws) → reduce (`summarizeThreadDigest`, `■現状` only,
/// always reads the *un*-refined joined lines regardless of whether refine
/// ran). `summarizePlain`/`summarize` (the single-message compression path)
/// are never touched by any of this — compression and fact-extraction are
/// separate protocol methods with separate call counters.
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
        // 3 messages == the refine skip threshold, so refine never runs.
        #expect(await service.refineThreadEntriesCallCount == 0)
        // The whole point of this redesign: the map step is fact-extraction
        // (`summarizeThreadEntry`), never the compression methods
        // (`summarizePlain`/`summarize`) a single-message summary uses.
        #expect(await service.summarizePlainCallCount == 0)
        #expect(await service.summarizeCallCount == 0)
    }

    @Test("assembles ■経緯 as an app-built bullet list (no refine, no reduce-step model call for it) below the refine threshold, then ■現状 from summarizeThreadDigest")
    func assemblesProgressWithoutModelReductionBelowThreshold() async throws {
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
        // exactly `expectedCombined` (the same joined text `■経緯` displays,
        // since refine is skipped below the threshold).
        let expectedCurrentStatus = "■現状\n[ja] \(expectedCombined)"
        let expected = "■経緯\n\(expectedCombined)\n\n\(expectedCurrentStatus)"

        #expect(result == expected)
        #expect(await service.refineThreadEntriesCallCount == 0)
    }

    @Test("above the refine threshold, refineThreadEntries runs exactly once and its output becomes ■経緯 — summarizeThreadDigest still reads the unrefined combined text")
    func refinesAboveThreshold() async throws {
        let service = FakeTranslationService()
        let messages = (1...4).map {
            ThreadDigestMessage(header: "[7/2\($0)] 田中:", text: "メッセージ\($0)の内容。")
        }

        let result = try await service.summarizeThread(messages, targetLanguage: .japanese)

        #expect(await service.summarizeThreadEntryCallCount == messages.count)
        // 4 messages > the refine skip threshold (3), so refine runs
        // exactly once.
        #expect(await service.refineThreadEntriesCallCount == 1)
        #expect(await service.summarizeThreadDigestCallCount == 1)

        let expectedCombined = messages.map { "\($0.header) [ja] \($0.text)" }.joined(separator: "\n")
        // `FakeTranslationService.refineThreadEntries` returns
        // `"■経緯\n[ja] <its own input verbatim>"` — its input is exactly
        // `expectedCombined`.
        let expectedProgress = "■経緯\n[ja] \(expectedCombined)"
        // `summarizeThreadDigest` (■現状) is fed the same *unrefined*
        // `expectedCombined` — never the refined `■経緯` text.
        let expectedCurrentStatus = "■現状\n[ja] \(expectedCombined)"
        #expect(result == "\(expectedProgress)\n\n\(expectedCurrentStatus)")
    }

    @Test("a refineThreadEntries failure falls back to the raw per-message ■経緯 list instead of failing the whole summary")
    func refineFailureFallsBackToRawList() async throws {
        let service = FakeTranslationService()
        await service.configureRefineThreadEntriesFailure(true)
        let messages = (1...4).map {
            ThreadDigestMessage(header: "[7/2\($0)] 田中:", text: "メッセージ\($0)の内容。")
        }

        let result = try await service.summarizeThread(messages, targetLanguage: .japanese)

        // Refine was attempted (and failed) exactly once — the fallback
        // doesn't retry it or skip calling it in the first place.
        #expect(await service.refineThreadEntriesCallCount == 1)
        // The overall call must still succeed (no error thrown) and still
        // produce a complete, correct ■現状.
        #expect(await service.summarizeThreadDigestCallCount == 1)

        let expectedCombined = messages.map { "\($0.header) [ja] \($0.text)" }.joined(separator: "\n")
        let expectedCurrentStatus = "■現状\n[ja] \(expectedCombined)"
        // ■経緯 falls back to the app-built raw list — exactly what it would
        // have been had refine been skipped entirely.
        #expect(result == "■経緯\n\(expectedCombined)\n\n\(expectedCurrentStatus)")
    }

    @Test("empty input short-circuits to an empty string without calling any step")
    func emptyInputSkipsEntirely() async throws {
        let service = FakeTranslationService()
        let result = try await service.summarizeThread([], targetLanguage: .japanese)
        #expect(result.isEmpty)
        #expect(await service.summarizeThreadEntryCallCount == 0)
        #expect(await service.summarizeThreadDigestCallCount == 0)
        #expect(await service.refineThreadEntriesCallCount == 0)
    }

    @Test("a single oversized message's text is chunked through summarizeThreadEntry, one call per chunk and no extra recombination call, refine skipped (1 message)")
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
        // 1 message <= the refine skip threshold.
        #expect(await service.refineThreadEntriesCallCount == 0)
    }

    @Test("onProgress reports .extractingMessage(1, n) through .extractingMessage(n, n), once per message in order, below the refine threshold")
    func reportsProgressPerMessageBelowThreshold() async throws {
        let service = FakeTranslationService()
        let messages = (1...3).map { ThreadDigestMessage(header: "[7/2\($0)] 田中:", text: "メッセージ\($0)") }

        actor ProgressRecorder {
            private(set) var events: [ThreadSummaryProgress] = []
            func record(_ event: ThreadSummaryProgress) { events.append(event) }
        }
        let recorder = ProgressRecorder()

        _ = try await service.summarizeThread(messages, targetLanguage: .japanese) { event in
            Task { await recorder.record(event) }
        }

        // Give the detached recording `Task`s a chance to land before
        // asserting — `onProgress` itself is synchronous from
        // `summarizeThread`'s point of view, so by the time it returns every
        // progress call has already been made (just possibly not yet
        // recorded by the actor).
        try await Task.sleep(nanoseconds: 50_000_000)
        let events = await recorder.events
        #expect(events == [
            .extractingMessage(current: 1, total: 3),
            .extractingMessage(current: 2, total: 3),
            .extractingMessage(current: 3, total: 3),
        ])
        // No `.refining` event — 3 messages is at the skip threshold.
        #expect(!events.contains(.refining))
    }

    @Test("onProgress additionally reports .refining exactly once, after every .extractingMessage event, above the refine threshold")
    func reportsRefiningEventAboveThreshold() async throws {
        let service = FakeTranslationService()
        let messages = (1...4).map { ThreadDigestMessage(header: "[7/2\($0)] 田中:", text: "メッセージ\($0)") }

        actor ProgressRecorder {
            private(set) var events: [ThreadSummaryProgress] = []
            func record(_ event: ThreadSummaryProgress) { events.append(event) }
        }
        let recorder = ProgressRecorder()

        _ = try await service.summarizeThread(messages, targetLanguage: .japanese) { event in
            Task { await recorder.record(event) }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let events = await recorder.events
        #expect(events == [
            .extractingMessage(current: 1, total: 4),
            .extractingMessage(current: 2, total: 4),
            .extractingMessage(current: 3, total: 4),
            .extractingMessage(current: 4, total: 4),
            .refining,
        ])
    }
}
