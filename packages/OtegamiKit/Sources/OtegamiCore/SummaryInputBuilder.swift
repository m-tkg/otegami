import Foundation

/// Builds the text handed to `TranslationService.summarizeLongText` from a
/// `QuoteStripper.SeparatedText` split — a small, independently testable
/// piece of `MessageView.sourceTextForSummary()`'s Task #62 logic (see that
/// method's doc comment for the full "why": a real-device report that
/// summaries still read like a recap of quoted reply history rather than
/// what the current message itself says).
///
/// When there's quoted context to include, the two are combined into a
/// structured, labeled string so
/// `FoundationModelsTranslationService.summarizeInstructions` can tell the
/// model to weight them differently — summarize the new part, use the
/// quoted part only as background. When there's no quoted context (the
/// common case: no quote marker found), `newText` is returned unchanged —
/// there's nothing to label.
///
/// Task #97: the quoted section is presented **first**, the new-text
/// section **second** — the reverse of Task #62's original ordering. A
/// real-device report said summaries narrated events out of chronological
/// order ("summarizes the new reply, then belatedly mentions the quoted
/// history") — an email's own new text is chronologically the *latest*
/// event, while the quote beneath it is the *earlier* history, so an LLM
/// asked to narrate "what happened" from input presented new-then-old tends
/// to reproduce that same backwards order in its output. Putting the quote
/// (earlier) before the new text (later) lines the input order up with
/// story order, so the model's natural "read top to bottom, narrate top to
/// bottom" tendency produces a chronologically-ordered summary instead of
/// fighting it. This is purely an input-ordering change — which section is
/// the *primary subject* of the summary is unchanged (still the new text;
/// see `FoundationModelsTranslationService.summarizeInstructions`).
public enum SummaryInputBuilder {
    /// Character cap applied to the quoted-context section — it's
    /// background, not the thing being summarized, so a long reply chain
    /// shouldn't be allowed to balloon the model input indefinitely the way
    /// the (unbounded) new-text section is allowed to (that side is safe
    /// because `summarizeLongText` already map-reduces oversized input via
    /// `TranslationChunker`). A character count, not an exact token budget,
    /// matching `TranslationChunker.defaultMaxChunkLength`'s own
    /// character-based heuristic.
    public static let quotedContextCharacterLimit = 600

    /// The section labels the model is told about in
    /// `FoundationModelsTranslationService.summarizeInstructions` — kept
    /// here as the single source of truth so the builder and the
    /// instructions can't drift apart. Reworded for Task #97 to spell out
    /// each section's *role* (context vs. summary target) rather than just
    /// its chronological position ("新規部分"/"過去のやり取り"), since the
    /// two sections no longer appear in "new, then old" reading order.
    public static let newTextSectionLabel = "■これが今回届いた返信 (要約対象)"
    public static let quotedTextSectionLabel = "■これは過去のやり取り (文脈参照用)"

    /// - Parameters:
    ///   - newText: the mail's own new text. Returned unchanged when
    ///     `quotedText` is empty.
    ///   - quotedText: prior-thread quote to include as context, truncated
    ///     to `characterLimit`. Passing an empty string is the same as
    ///     having no quote at all.
    ///   - characterLimit: override point for tests; production call sites
    ///     use the default.
    public static func build(newText: String, quotedText: String, characterLimit: Int = quotedContextCharacterLimit) -> String {
        guard !quotedText.isEmpty else { return newText }
        let truncatedQuote = String(quotedText.prefix(characterLimit))
        return """
        \(quotedTextSectionLabel):
        \(truncatedQuote)

        \(newTextSectionLabel):
        \(newText)
        """
    }
}
