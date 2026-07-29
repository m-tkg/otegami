import Foundation
import Testing
@testable import OtegamiCore

@Suite("SummaryInputBuilder")
struct SummaryInputBuilderTests {
    @Test("returns newText unchanged when there is no quoted context")
    func returnsNewTextUnchangedWhenNoQuote() {
        let newText = "This is the new part of the message."
        #expect(SummaryInputBuilder.build(newText: newText, hasQuotedContext: false) == newText)
    }

    @Test("prefixes the fixed note line ahead of newText when quoted context is present")
    func prefixesNoteLineWhenQuotedContextPresent() {
        let newText = "This is the new part of the message."
        let result = SummaryInputBuilder.build(newText: newText, hasQuotedContext: true)

        #expect(result.contains(SummaryInputBuilder.quotedContextNoteLine))
        #expect(result.contains(newText))

        // Task #134: the note comes first, newText second — same
        // chronological ordering #97 established, trivially true here
        // since the note carries no content of its own to get the
        // ordering wrong about.
        guard let noteRange = result.range(of: SummaryInputBuilder.quotedContextNoteLine), let newTextRange = result.range(of: newText) else {
            Issue.record("expected both the note line and newText to be present in the result")
            return
        }
        #expect(noteRange.lowerBound < newTextRange.lowerBound)
    }

    @Test("never embeds any quoted text content — only the fixed note line")
    func neverEmbedsQuotedTextContent() {
        // Task #134's whole point: earlier revisions accepted the quoted
        // thread's actual text and (truncated/labeled/reordered) embedded
        // it in the model's input. `build` no longer takes that text at
        // all — this test exists mainly to document that `hasQuotedContext`
        // is a `Bool`, not a `String`, so there's no accidental way for a
        // future edit to reintroduce quoted content here without changing
        // this signature first.
        let newText = "Thanks, see you then."
        let result = SummaryInputBuilder.build(newText: newText, hasQuotedContext: true)
        let expected = "\(SummaryInputBuilder.quotedContextNoteLine)\n\n\(newText)"
        #expect(result == expected)
    }
}
