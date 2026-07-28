import Foundation
import Testing
@testable import OtegamiCore

@Suite("SummaryInputBuilder")
struct SummaryInputBuilderTests {
    @Test("returns newText unchanged when there is no quoted context")
    func returnsNewTextUnchangedWhenNoQuote() {
        let newText = "This is the new part of the message."
        #expect(SummaryInputBuilder.build(newText: newText, quotedText: "") == newText)
    }

    @Test("wraps both sections in labeled headers when quoted context is present")
    func buildsLabeledStructuredInput() {
        let newText = "This is the new part of the message."
        let quotedText = "This is the quoted history."
        let result = SummaryInputBuilder.build(newText: newText, quotedText: quotedText)

        #expect(result.contains(SummaryInputBuilder.newTextSectionLabel))
        #expect(result.contains(SummaryInputBuilder.quotedTextSectionLabel))
        #expect(result.contains(newText))
        #expect(result.contains(quotedText))
        // The new-text section must precede the quoted-context section —
        // Task #62's whole point is that the new part is the primary
        // subject and the quote is background read after it.
        let newTextRange = try? #require(result.range(of: newText))
        let quotedTextRange = try? #require(result.range(of: quotedText))
        if let newTextRange, let quotedTextRange {
            #expect(newTextRange.lowerBound < quotedTextRange.lowerBound)
        }
    }

    @Test("truncates quoted context to the character limit, keeping newText intact")
    func truncatesQuotedContextToCharacterLimit() {
        let newText = "This is the new part of the message."
        let quotedText = String(repeating: "x", count: 2000)
        let result = SummaryInputBuilder.build(newText: newText, quotedText: quotedText, characterLimit: 100)

        #expect(result.contains(newText))
        #expect(!result.contains(String(repeating: "x", count: 101)))
        #expect(result.contains(String(repeating: "x", count: 100)))
    }

    @Test("default character limit matches the documented constant")
    func defaultCharacterLimitIsApplied() {
        let quotedText = String(repeating: "y", count: SummaryInputBuilder.quotedContextCharacterLimit + 500)
        let result = SummaryInputBuilder.build(newText: "new", quotedText: quotedText)
        #expect(!result.contains(String(repeating: "y", count: SummaryInputBuilder.quotedContextCharacterLimit + 1)))
    }
}
