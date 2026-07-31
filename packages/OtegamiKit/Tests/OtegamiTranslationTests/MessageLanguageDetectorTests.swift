#if canImport(NaturalLanguage)
import Testing
@testable import OtegamiTranslation

@Suite("MessageLanguageDetector")
struct MessageLanguageDetectorTests {
    @Test("detects English prose")
    func detectsEnglish() {
        let text = "Hi team, the quarterly report is attached. Please review it by Friday and send me your comments. Thanks!"
        #expect(MessageLanguageDetector.detect(text) == "en")
        #expect(MessageLanguageDetector.isEnglish(text) == true)
    }

    @Test("detects Japanese prose")
    func detectsJapanese() {
        let text = "test1 さん、ようこそ otegami へ。四半期レポートを添付しました。金曜日までにご確認いただき、コメントをお送りください。"
        #expect(MessageLanguageDetector.detect(text) == "ja")
        #expect(MessageLanguageDetector.isEnglish(text) == false)
    }

    @Test("a mixed-language body still resolves to a single dominant language")
    func detectsMixedDominant() {
        // Mostly Japanese, with a short English proper noun/quoted phrase —
        // NLLanguageRecognizer should still commit to "ja" as dominant.
        let text = """
        田中さん、お世話になっております。プロジェクト "Otegami Mail Client" の件でご連絡しました。
        添付の資料をご確認いただき、来週までにフィードバックをいただけますと幸いです。
        引き続きよろしくお願いいたします。
        """
        #expect(MessageLanguageDetector.detect(text) == "ja")
    }

    @Test("blank input returns nil")
    func blankInput() {
        #expect(MessageLanguageDetector.detect("") == nil)
        #expect(MessageLanguageDetector.detect("   \n\n  ") == nil)
    }

    @Test("symbols-only input returns nil rather than a confident guess")
    func symbolsOnly() {
        #expect(MessageLanguageDetector.detect("*** --- === ### $$$ !!! ???") == nil)
    }

    @Test("very short input either returns nil or a plausible language, never crashes")
    func shortInput() {
        // NLLanguageRecognizer's confidence on 1-2 words is inherently
        // fuzzy — this test only pins down that it doesn't crash/hang, not
        // a specific answer.
        _ = MessageLanguageDetector.detect("OK")
        _ = MessageLanguageDetector.detect("了解")
    }
}

// MARK: - Task #203: HTML/plain-text fallback

/// Synthetic construction with a *known*, deliberately low letter ratio —
/// not real HTML, but shaped like the diagnostics screen's real reported
/// breakdown for a broken HTML-extraction sample (`letters=14% digits=0%
/// otherSymbols=37%`, the rest whitespace/`=`): mostly symbol noise, with
/// only a couple of literal letters (`td`) per repetition standing in for
/// stray tag-name-like remnants surviving extraction. Deliberately has no
/// `<`/`>` of its own — used both as a raw `plainText` candidate (used
/// as-is) *and* as a raw `html` candidate (run through `HTMLTextExtractor`
/// first): without `<`/`>`, the extractor finds no tags to strip and
/// passes it through unchanged, so both call sites see the same ratio. 15
/// repetitions of a 21-symbol/2-letter unit works out to roughly an 8-9%
/// letter ratio — comfortably below `MessageLanguageDetector
/// .minLetterRatio` (0.3), same as the real failing sample was.
let taskNumber203MarkupNoise: String = {
    let noiseUnit = "=0:1;2,3-4_5.6/7\\8~9"
    let letterUnit = "td"
    var result = ""
    for _ in 0..<15 {
        result += noiseUnit
        result += letterUnit
    }
    return result
}()

@Suite("MessageLanguageDetector.letterRatio / isTooNoisyToTrust")
struct MessageLanguageDetectorLetterRatioTests {
    @Test("clean English prose has a high letter ratio")
    func cleanProseHasHighRatio() throws {
        let text = "Hi team, the quarterly report is attached. Please review it by Friday."
        let ratio = try #require(MessageLanguageDetector.letterRatio(text))
        #expect(ratio > 0.7)
        #expect(!MessageLanguageDetector.isTooNoisyToTrust(text))
    }

    @Test("markup-contaminated text mirroring the real Task #203 failure sample has a low letter ratio")
    func markupContaminatedTextHasLowRatio() throws {
        let text = taskNumber203MarkupNoise
        let ratio = try #require(MessageLanguageDetector.letterRatio(text))
        #expect(ratio < MessageLanguageDetector.minLetterRatio)
        #expect(MessageLanguageDetector.isTooNoisyToTrust(text))
    }

    @Test("empty or whitespace-only text has no letter ratio and is treated as too noisy")
    func emptyTextHasNoRatio() {
        #expect(MessageLanguageDetector.letterRatio("") == nil)
        #expect(MessageLanguageDetector.letterRatio("   \n\n  ") == nil)
        #expect(MessageLanguageDetector.isTooNoisyToTrust(""))
        #expect(MessageLanguageDetector.isTooNoisyToTrust("   \n\n  "))
    }
}

@Suite("MessageLanguageDetector.detectWithFallback")
struct MessageLanguageDetectorFallbackTests {
    static let cleanEnglish = "Hi team, the quarterly report is attached. Please review it by Friday and send me your comments."
    static let cleanJapanese = "田中さん、お世話になっております。添付の資料をご確認いただき、来週までにフィードバックをいただけますと幸いです。"
    /// `taskNumber203MarkupNoise` — stands in for "HTML の構造が壊れている"
    /// extraction output (see its doc comment for why its letter ratio is
    /// deliberately low).
    static let markupNoise = taskNumber203MarkupNoise

    @Test("a clean plainText candidate wins even when html is present and clean too")
    func plainTextPreferredWhenBothClean() throws {
        let outcome = try #require(MessageLanguageDetector.detectWithFallback(
            plainText: Self.cleanEnglish,
            html: "<p>\(Self.cleanJapanese)</p>"
        ))
        #expect(outcome.language == "en")
        #expect(outcome.source == .plainText)
    }

    @Test("falls back to HTML-extracted text when plainText is missing")
    func fallsBackToHTMLWhenPlainTextMissing() throws {
        let outcome = try #require(MessageLanguageDetector.detectWithFallback(
            plainText: nil,
            html: "<p>\(Self.cleanEnglish)</p>"
        ))
        #expect(outcome.language == "en")
        #expect(outcome.source == .html)
    }

    @Test("falls back to HTML-extracted text when plainText is empty")
    func fallsBackToHTMLWhenPlainTextEmpty() throws {
        let outcome = try #require(MessageLanguageDetector.detectWithFallback(
            plainText: "",
            html: "<p>\(Self.cleanEnglish)</p>"
        ))
        #expect(outcome.language == "en")
        #expect(outcome.source == .html)
    }

    @Test("falls back to HTML-extracted text when plainText is markup noise (this task's reported failure shape)")
    func fallsBackToHTMLWhenPlainTextIsNoisy() throws {
        // Mirrors the reported bug in reverse of what's usually assumed:
        // here it's the *plainText* candidate that's unusable and the HTML
        // side that's clean, exercising the fallback direction opposite
        // `plainTextPreferredWhenBothClean` above.
        let outcome = try #require(MessageLanguageDetector.detectWithFallback(
            plainText: Self.markupNoise,
            html: "<p>\(Self.cleanEnglish)</p>"
        ))
        #expect(outcome.language == "en")
        #expect(outcome.source == .html)
    }

    @Test("falls back to plainText when HTML extracts to markup noise — the reported Task #203 shape")
    func fallsBackToPlainTextWhenHTMLIsNoisy() throws {
        let outcome = try #require(MessageLanguageDetector.detectWithFallback(
            plainText: Self.cleanEnglish,
            html: Self.markupNoise
        ))
        #expect(outcome.language == "en")
        #expect(outcome.source == .plainText)
    }

    @Test("returns nil when both candidates are missing")
    func nilWhenBothMissing() {
        #expect(MessageLanguageDetector.detectWithFallback(plainText: nil, html: nil) == nil)
    }

    @Test("returns nil when both candidates are empty")
    func nilWhenBothEmpty() {
        #expect(MessageLanguageDetector.detectWithFallback(plainText: "", html: "") == nil)
    }

    @Test("returns nil when both candidates are markup noise")
    func nilWhenBothNoisy() {
        #expect(MessageLanguageDetector.detectWithFallback(plainText: Self.markupNoise, html: Self.markupNoise) == nil)
    }

    @Test("returns nil when plainText is missing and there is no html candidate either")
    func nilWhenPlainTextMissingAndNoHTML() {
        #expect(MessageLanguageDetector.detectWithFallback(plainText: nil, html: nil) == nil)
    }
}
#endif
