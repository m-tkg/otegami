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
        // The quoted-context section must precede the new-text section —
        // Task #97: the quote is chronologically the *earlier* part of the
        // conversation (it's the history being replied to) while the new
        // text is the *latest* event, so presenting the quote first lines
        // the input order up with chronological order. This is the
        // opposite of Task #62's original "new text first" ordering, which
        // a real-device report said made summaries narrate events
        // backwards (new reply described first, quoted history mentioned
        // as an afterthought). The new text remains the summary's primary
        // *subject* regardless of this input ordering — that's enforced by
        // `FoundationModelsTranslationService.summarizeInstructions`, not
        // by section order.
        guard let quotedTextRange = result.range(of: quotedText), let newTextRange = result.range(of: newText) else {
            Issue.record("expected both newText and quotedText to be present in the result")
            return
        }
        #expect(quotedTextRange.lowerBound < newTextRange.lowerBound)
    }

    @Test("labels the quoted section as past context and the new section as the reply to summarize")
    func labelsReflectChronologicalRoles() {
        // Task #97: labels spell out each section's *role* now that they
        // no longer appear in "new, then old" order — asserting on the
        // exact wording (rather than just presence, which the test above
        // already covers) guards against a future edit reintroducing
        // wording that implies the old "new part / quoted part" framing
        // without the context-vs-target distinction.
        #expect(SummaryInputBuilder.quotedTextSectionLabel.contains("過去のやり取り"))
        #expect(SummaryInputBuilder.newTextSectionLabel.contains("要約対象"))
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
