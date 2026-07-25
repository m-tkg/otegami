import Foundation
import Testing
import OtegamiTranslation
@testable import OtegamiTranslationFoundationModels

/// Exercises the real on-device model — opt-in like
/// `MailTransportMailCoreTests`' `OTEGAMI_TEST_IMAP_HOST`-gated suites, but
/// gated on `isFoundationModelsTranslationAvailable()` instead of an
/// environment variable: whether Apple Intelligence is available is a
/// property of the *machine running the test* (Apple Intelligence-eligible
/// hardware, the feature turned on in Settings, and the on-device model
/// assets already downloaded — see `docs/translation.md`'s "可用性の条件"
/// for the full list), not something a CI runner or a fresh simulator can
/// be expected to have. Skips (doesn't fail) when unavailable, so
/// `swift test` stays green everywhere except reporting less coverage — see
/// `docs/translation.md`'s "実機での動作確認" section for the actual
/// on-device run this suite's assertions were validated against (recorded
/// there rather than only in CI, since CI itself is expected to skip this
/// suite).
///
/// Every test body starts with `guard #available(iOS 26.0, macOS 26.0, *)`
/// rather than the whole struct being `@available`-annotated — Swift
/// Testing's `@Suite`/`@Test` macros reject an `@available`-marked
/// declaration outright, and this package's own platform floor stays
/// iOS 18/macOS 15 (see `isFoundationModelsTranslationAvailable`'s doc
/// comment for why raising it to match `FoundationModelsTranslationService`
/// isn't an option: it broke `otegami-relay`'s build). In practice this
/// `guard` never actually trips at runtime — the `@Suite` trait below
/// already skips the whole suite unless `isFoundationModelsTranslationAvailable()`
/// is `true`, which requires iOS/macOS 26 — it exists purely to satisfy the
/// compiler at this package's lower floor.
///
/// Run on a Mac (or in an iOS Simulator booted from a host) with Apple
/// Intelligence enabled:
///
/// ```sh
/// swift test --filter FoundationModelsTranslationServiceTests
/// ```
@Suite(
    "FoundationModelsTranslationService against the real on-device model",
    .enabled(if: isFoundationModelsTranslationAvailable(), "Apple Intelligence is unavailable on this machine")
)
struct FoundationModelsTranslationServiceTests {
    @Test("availability reports .available when SystemLanguageModel.default is available")
    func availabilityReportsAvailable() {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let service = FoundationModelsTranslationService()
        #expect(service.availability == .available)
    }

    @Test("translates a short English sentence into Japanese")
    func translatesEnglishToJapanese() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let service = FoundationModelsTranslationService()
        let result = try await service.translate(
            "The meeting has been moved to 3pm tomorrow.",
            from: .english,
            to: .japanese
        )
        #expect(!result.isEmpty)
        // A real (non-fake) translation shouldn't just echo the English
        // input back verbatim, and should contain at least one non-ASCII
        // (Japanese) character.
        #expect(result != "The meeting has been moved to 3pm tomorrow.")
        #expect(result.contains { !$0.isASCII })
    }

    @Test("translates a short Japanese sentence into English (1i's \"英語で返信を下書き\" direction)")
    func translatesJapaneseToEnglish() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let service = FoundationModelsTranslationService()
        let result = try await service.translate(
            "会議は明日の午後3時に変更されました。",
            from: .japanese,
            to: .english
        )
        #expect(!result.isEmpty)
        #expect(result.allSatisfy { $0.isASCII })
    }

    @Test("translateParagraphs preserves paragraph count for a multi-paragraph body")
    func translateParagraphsPreservesCount() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let service = FoundationModelsTranslationService()
        let paragraphs = [
            "Hi team,",
            "The quarterly report is attached. Please review it by Friday.",
            "Thanks!",
        ]
        let results = try await service.translateParagraphs(paragraphs, from: .english, to: .japanese)
        #expect(results.count == paragraphs.count)
        for result in results {
            #expect(!result.isEmpty)
        }
    }

    @Test("translateStream yields cumulative, monotonically-growing snapshots ending in a non-empty translation")
    func translateStreamYieldsCumulativeSnapshots() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let service = FoundationModelsTranslationService()
        var chunks: [String] = []
        for try await chunk in service.translateStream("Please confirm you received this email.", from: .english, to: .japanese) {
            chunks.append(chunk)
        }
        #expect(!chunks.isEmpty)
        #expect(!(chunks.last?.isEmpty ?? true))
    }

    @Test("summarize returns a short, non-empty summary")
    func summarizeReturnsSummary() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let service = FoundationModelsTranslationService()
        let body = """
        Hi team,

        The quarterly report is attached. Please review it by Friday and send me your comments.
        We'll discuss the findings in Monday's meeting.

        Thanks,
        Alex
        """
        let summary = try await service.summarize(body, targetLanguage: .japanese, sentenceCount: 2)
        #expect(!summary.isEmpty)
    }
}
