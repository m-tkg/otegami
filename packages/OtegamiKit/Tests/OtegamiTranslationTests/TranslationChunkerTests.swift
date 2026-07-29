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

    // MARK: - Phase 5 (2026-07-30, real-device log `dd58453`): blank/invisible
    // input must chunk to `[]` the same as literal empty input, not just
    // Swift's `isEmpty` — sending the Translation engine a "paragraph" with
    // nothing to identify a language from failed as `TranslationErrorDomain
    // Code=21` ("Client asked to translate batch of 0 inputs") on-device.

    @Test("whitespace-only input returns no chunks, same as empty input")
    func whitespaceOnlyInputReturnsNoChunks() {
        #expect(TranslationChunker.chunk("   ", maxLength: 200) == [])
        #expect(TranslationChunker.chunk("\n\t\n", maxLength: 200) == [])
    }

    @Test("a lone zero-width space returns no chunks — non-empty by String.isEmpty but no actual translatable content")
    func zeroWidthSpaceOnlyInputReturnsNoChunks() {
        #expect(TranslationChunker.chunk("\u{200B}", maxLength: 200) == [])
    }

    @Test("other invisible/format characters (word joiner, soft hyphen, BOM) also return no chunks")
    func otherInvisibleCharactersReturnNoChunks() {
        #expect(TranslationChunker.chunk("\u{2060}", maxLength: 200) == [])
        #expect(TranslationChunker.chunk("\u{00AD}", maxLength: 200) == [])
        #expect(TranslationChunker.chunk("\u{FEFF}", maxLength: 200) == [])
        #expect(TranslationChunker.chunk(" \u{200B}\n\u{00AD} ", maxLength: 200) == [])
    }

    @Test("a real (even very short) word alongside invisible characters is still returned")
    func shortRealContentIsNotTreatedAsBlank() {
        #expect(TranslationChunker.chunk("\u{200B}Hi", maxLength: 200) == ["\u{200B}Hi"])
    }
}
