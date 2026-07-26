import Testing
@testable import OtegamiTranslation

@Suite("TranslationChunker")
struct TranslationChunkerTests {
    @Test("text within the limit is returned unchanged, as a single chunk")
    func withinLimitIsUnchanged() {
        let text = "Hi team, the quarterly report is attached."
        #expect(TranslationChunker.chunk(text, maxLength: 200) == [text])
    }

    @Test("empty input returns no chunks")
    func emptyInput() {
        #expect(TranslationChunker.chunk("", maxLength: 200) == [])
    }

    @Test("splits at sentence boundaries, keeping every chunk within the limit")
    func splitsAtSentenceBoundaries() {
        let text = "Sentence one is here. Sentence two is here. Sentence three is here."
        let chunks = TranslationChunker.chunk(text, maxLength: 30)
        for chunk in chunks {
            #expect(chunk.count <= 30)
        }
        // Rejoining every chunk (space-separated, matching how
        // `MessageTranslator` regroups translated chunks) reconstructs the
        // original sentences without losing or duplicating any of them.
        #expect(chunks.joined(separator: " ") == text)
    }

    @Test("a single sentence longer than the limit is hard-sliced rather than left oversized")
    func hardSlicesAnOversizedSentence() {
        let longWord = String(repeating: "a", count: 55)
        let chunks = TranslationChunker.chunk(longWord, maxLength: 20)
        #expect(chunks.count == 3)
        for chunk in chunks {
            #expect(chunk.count <= 20)
        }
        #expect(chunks.joined() == longWord)
    }

    @Test("prefers line breaks over hard-slicing for punctuation-free multi-line text")
    func splitsOnLineBreaksWithoutPunctuation() {
        let text = (1...5).map { "item \($0) with no terminating punctuation" }.joined(separator: "\n")
        let chunks = TranslationChunker.chunk(text, maxLength: 60)
        for chunk in chunks {
            #expect(chunk.count <= 60)
        }
        // Every line survives somewhere in the chunked output.
        for line in text.split(separator: "\n") {
            #expect(chunks.contains { $0.contains(line) })
        }
    }

    @Test("Japanese sentence terminators are also recognized as split points")
    func splitsOnJapaneseTerminators() {
        let text = "これは一文目です。これは二文目です。これは三文目です。"
        let chunks = TranslationChunker.chunk(text, maxLength: 15)
        for chunk in chunks {
            #expect(chunk.count <= 15)
        }
        #expect(chunks.joined() == text)
    }
}
