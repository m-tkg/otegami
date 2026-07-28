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
    /// instructions can't drift apart.
    public static let newTextSectionLabel = "■このメールの新規部分"
    public static let quotedTextSectionLabel = "■引用されている過去のやり取り (文脈)"

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
        \(newTextSectionLabel):
        \(newText)

        \(quotedTextSectionLabel):
        \(truncatedQuote)
        """
    }
}
