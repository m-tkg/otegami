import Testing
@testable import OtegamiTranslation

@Suite("ParagraphSplitter")
struct ParagraphSplitterTests {
    @Test("splits on blank lines")
    func splitsOnBlankLines() {
        let text = "Hello team,\n\nThe report is attached.\n\nThanks!"
        #expect(ParagraphSplitter.split(text) == [
            "Hello team,",
            "The report is attached.",
            "Thanks!",
        ])
    }

    @Test("a single-line body with no blank lines is one paragraph")
    func singleParagraph() {
        #expect(ParagraphSplitter.split("Just one line, no breaks.") == ["Just one line, no breaks."])
    }

    @Test("multi-line paragraphs keep their internal line breaks")
    func multiLineParagraph() {
        let text = "Line one\nLine two\n\nSecond paragraph"
        #expect(ParagraphSplitter.split(text) == ["Line one\nLine two", "Second paragraph"])
    }

    @Test("three or more consecutive blank lines don't produce an empty paragraph")
    func collapsesExtraBlankLines() {
        let text = "First\n\n\n\nSecond"
        #expect(ParagraphSplitter.split(text) == ["First", "Second"])
    }

    @Test("leading/trailing whitespace on a paragraph is trimmed")
    func trimsWhitespace() {
        let text = "  Hello   \n\n  World  "
        #expect(ParagraphSplitter.split(text) == ["Hello", "World"])
    }

    @Test("blank or whitespace-only input returns no paragraphs")
    func blankInput() {
        #expect(ParagraphSplitter.split("") == [])
        #expect(ParagraphSplitter.split("   \n\n  \n") == [])
    }
}
