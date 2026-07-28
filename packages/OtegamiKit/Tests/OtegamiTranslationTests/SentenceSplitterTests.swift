import Testing
@testable import OtegamiTranslation

@Suite("SentenceSplitter")
struct SentenceSplitterTests {
    @Test("splits on ASCII terminators, keeping the terminator")
    func splitsOnASCIITerminators() {
        let text = "First sentence. Second sentence! Third sentence?"
        #expect(SentenceSplitter.split(text) == [
            "First sentence.",
            "Second sentence!",
            "Third sentence?",
        ])
    }

    @Test("splits on Japanese (fullwidth) terminators, including the fullwidth period")
    func splitsOnJapaneseTerminators() {
        let text = "一文目。二文目．三文目！四文目？"
        #expect(SentenceSplitter.split(text) == [
            "一文目。",
            "二文目．",
            "三文目！",
            "四文目？",
        ])
    }

    @Test("a line break also ends a sentence-like unit, for text with no terminator at all")
    func splitsOnLineBreaksWithoutTerminators() {
        let text = "First line\nSecond line\nThird line"
        #expect(SentenceSplitter.split(text) == ["First line", "Second line", "Third line"])
    }

    @Test("text with no terminator or line break at all is one sentence")
    func noTerminatorIsOneSentence() {
        #expect(SentenceSplitter.split("Just one run-on unit with no punctuation") == ["Just one run-on unit with no punctuation"])
    }

    @Test("blank or whitespace-only input returns no sentences")
    func blankInput() {
        #expect(SentenceSplitter.split("") == [])
        #expect(SentenceSplitter.split("   \n  \n") == [])
    }

    @Test("surrounding whitespace on each sentence is trimmed")
    func trimsWhitespace() {
        let text = "  First sentence.   Second sentence.  "
        #expect(SentenceSplitter.split(text) == ["First sentence.", "Second sentence."])
    }
}
