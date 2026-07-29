import Foundation

/// Task #159 (メール翻訳を Apple Translation フレームワークの専用 NMT へ切替):
/// the translate-only half of what used to be `TranslationService`'s full
/// method set — split out so a translation-only engine
/// (`OtegamiTranslationApple`'s `AppleTranslationService`, backed by
/// `Translation.TranslationSession`) can conform without also having to
/// implement `summarize`/`summarizePlain`/`summarizeThreadDigest`, which stay
/// on `FoundationModelsTranslationService` (a general-purpose on-device LLM
/// remains the right tool for summarization; a dedicated NMT model is not).
///
/// `TranslationService` below refines this protocol (adds the summarize
/// methods) rather than duplicating these three, so every existing conformer
/// (`FakeTranslationService`, `FoundationModelsTranslationService`) — both
/// unions already implement translate+summarize — automatically satisfies
/// `TranslationOnlyService` too with no changes of their own. `HybridTranslationService`
/// (this target) is what actually composes a `TranslationOnlyService` (for
/// translate) with an `any TranslationService` (for summarize) back into a
/// full `TranslationService` `AppEnvironment` can hand to `MessageTranslator`.
public protocol TranslationOnlyService: Sendable {
    /// Whether this engine can translate right now. Checked before
    /// `translate`/`translateStream` are attempted so a caller can show
    /// "翻訳は利用できません" instead of a spinner that never resolves;
    /// `translate`/`translateStream` should still be assumed capable of
    /// throwing `.unavailable` themselves (availability can change between
    /// this check and the call — e.g. the on-device model gets evicted
    /// under memory pressure).
    var availability: TranslationAvailability { get }

    /// Translates `text` as a single unit, returning once the whole
    /// translation is ready. For a long message body, prefer
    /// `translateStream` (perceived latency) or `translateParagraphs`
    /// (needed for 1i's per-paragraph original/translated toggle) —
    /// `translate` exists for short strings where streaming would be
    /// overkill: a list row's "翻訳" action on a snippet, a subject line, a
    /// compose draft's "英語で下書き" pass over a short reply.
    func translate(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) async throws -> String

    /// Translates each of `paragraphs` independently, returning results in
    /// the same order and count as the input — the alignment
    /// `MessageTranslator`/`MessageTranslationRecord.paragraphs` needs so a
    /// long-press on paragraph *N* of the rendered translation can show
    /// paragraph *N* of the original (design handoff 1i). Implementations
    /// should translate paragraphs independently rather than splitting a
    /// single combined response — joining then re-splitting on a delimiter
    /// the model might echo back verbatim (or alter) is fragile; one
    /// request per paragraph is slower but never mis-aligns.
    ///
    /// `paragraphs.isEmpty` returns `[]` without engaging the engine.
    func translateParagraphs(_ paragraphs: [String], from source: TranslationLanguage, to target: TranslationLanguage) async throws -> [String]

    /// Streams `text`'s translation incrementally. Each yielded element is
    /// the *cumulative* translation so far (matching
    /// `LanguageModelSession.streamResponse`'s own snapshot semantics —
    /// see `FoundationModelsTranslationService`'s doc comment), not a
    /// delta: a caller renders the latest element and discards the rest,
    /// it never concatenates them. The stream finishes normally after the
    /// final (complete) element, or throws `TranslationServiceError` if
    /// generation fails partway through.
    ///
    /// `AppleTranslationService`'s conformance is the one place this
    /// "cumulative snapshot" contract degenerates to a single element — the
    /// Translation framework's NMT has no incremental/partial output the way
    /// an LLM's token-by-token generation does, so there's only ever one,
    /// already-final snapshot to yield. Still a valid conformance: "the
    /// latest yielded element" and "the only yielded element" are the same
    /// thing in that case.
    func translateStream(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) -> AsyncThrowingStream<String, Error>
}
