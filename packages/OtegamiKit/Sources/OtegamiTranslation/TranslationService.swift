import Foundation

/// The single seam between "otegami translates mail" and any particular
/// engine that does the translating. Everything above this protocol
/// (`TranslationEngine`'s cache-aware `MessageTranslator`, and eventually
/// the UI phase's views) talks only to `TranslationService` — never to
/// `FoundationModels` directly — so:
///
///  - `FakeTranslationService` (this target) can stand in for tests and
///    previews with deterministic, instant output.
///  - `FoundationModelsTranslationService` (`OtegamiTranslationFoundationModels`,
///    a separate Apple-only target) is the only file in this codebase that
///    imports `FoundationModels`. A build without that framework — an
///    older SDK, a hypothetical Linux tool — never needs to know it exists.
///  - A future engine (a different on-device model, a opt-in cloud
///    fallback, ...) is a new conformer, not a rewrite of every call site.
///
/// This mirrors `MailTransport`'s `IMAPSessionProtocol`/
/// `SMTPSessionProtocol` split from `MailTransportMailCore`'s MailCore2
/// implementation — same shape, same reason.
///
/// All methods are `async` even though `FakeTranslationService` could
/// answer synchronously: `FoundationModelsTranslationService` always has
/// real latency (on-device inference, not instant), and a protocol that's
/// sometimes-sync-sometimes-async would force every caller to abstract over
/// that difference anyway. Better to make the async cost visible everywhere
/// from the start.
public protocol TranslationService: Sendable {
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
    func translateStream(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) -> AsyncThrowingStream<String, Error>

    /// A short summary of `text` in `targetLanguage`, roughly
    /// `sentenceCount` sentences — the design handoff's 1e list-row summary
    /// treatment ("英文行は...日本語要約2行"). `sentenceCount` is a
    /// request, not a guarantee; engines should treat it as a strong hint
    /// about desired length rather than a hard constraint the caller can
    /// rely on for layout.
    func summarize(_ text: String, targetLanguage: TranslationLanguage, sentenceCount: Int) async throws -> String
}

extension TranslationService {
    /// Most callers want a 2-sentence summary (the 1e list-row treatment) —
    /// this default keeps call sites from repeating that number.
    public func summarize(_ text: String, targetLanguage: TranslationLanguage) async throws -> String {
        try await summarize(text, targetLanguage: targetLanguage, sentenceCount: 2)
    }
}
