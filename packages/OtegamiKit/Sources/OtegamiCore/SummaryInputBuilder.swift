import Foundation

/// Builds the text handed to `TranslationService.summarizeLongText` from a
/// `QuoteStripper.SeparatedText` split — a small, independently testable
/// piece of `MessageView.sourceTextForSummary()`'s Task #62 logic (see that
/// method's doc comment for the full "why": a real-device report that
/// summaries still read like a recap of quoted reply history rather than
/// what the current message itself says).
///
/// Task #134 (根治): every earlier revision of this type (#62 through #132)
/// tried to fix quote leakage by changing *how* the quoted text was
/// presented to the model — truncating it, labeling it, reordering it
/// relative to the new text, telling the model in ever more specific
/// language not to summarize it. A real-device repro (the mail behind
/// Task #132, continuing to leak quoted content even after #132's
/// instruction hardening) traced the actual root cause one level lower:
/// no amount of prompt wording reliably stops an on-device model from
/// treating *some* fragment of real prior-thread text as summarizable
/// content once that text is present in its input at all. The fix here is
/// structural instead of another wording iteration — stop handing the
/// model the quoted text's content in the first place. When there *is* a
/// quoted prior thread underneath the new text, `build` now includes only
/// `quotedContextNoteLine`, a fixed one-line note that this reply follows
/// a prior exchange whose text has been omitted — nothing left to leak,
/// borrow a topic from, or narrate out of chronological order (obsoleting
/// the #97 section-ordering concern along with it). See
/// `FoundationModelsTranslationService.summarizeInstructions`'s doc
/// comment for how the model is told to use (and not overuse) that note.
public enum SummaryInputBuilder {
    /// The fixed note appended ahead of `newText` when the message had a
    /// quoted prior thread underneath it. Deliberately contains no content
    /// from the quote itself — see this type's doc comment (Task #134).
    /// Kept here as the single source of truth so `build` and
    /// `FoundationModelsTranslationService.summarizeInstructions` (which
    /// references this exact string so it can tell the model how to treat
    /// it) can't drift apart.
    public static let quotedContextNoteLine = "(この返信は過去のやり取りへの返信。引用本文は省略している)"

    /// - Parameters:
    ///   - newText: the mail's own new text. Returned unchanged when
    ///     `hasQuotedContext` is false.
    ///   - hasQuotedContext: whether the message had a quoted prior thread
    ///     underneath its new text (`QuoteStripper.SeparatedText.quotedText`
    ///     non-empty). Task #134: callers no longer need to hand over that
    ///     quoted text's actual content — only whether it existed — since
    ///     `build` never embeds it.
    public static func build(newText: String, hasQuotedContext: Bool) -> String {
        guard hasQuotedContext else { return newText }
        return """
        \(quotedContextNoteLine)

        \(newText)
        """
    }
}
