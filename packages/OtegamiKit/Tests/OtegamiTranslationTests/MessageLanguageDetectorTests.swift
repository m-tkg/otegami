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
#endif
