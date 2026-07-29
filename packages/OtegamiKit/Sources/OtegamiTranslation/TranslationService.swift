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
///
/// Task #159 (メール翻訳を Apple Translation フレームワークの専用 NMT へ切替):
/// refines `TranslationOnlyService` (this target) rather than re-declaring
/// `translate`/`translateParagraphs`/`translateStream`/`availability` itself
/// — those three methods are the half of this contract a translation-only
/// engine (`OtegamiTranslationApple`'s `AppleTranslationService`) can
/// conform to without also implementing summarization, which stays on
/// `FoundationModelsTranslationService` (`HybridTranslationService`, this
/// target, is what recombines the two into a single `TranslationService`
/// `AppEnvironment` hands out). Every existing conformer here already
/// implements all of `TranslationOnlyService`'s requirements, so this
/// refinement needed no changes to `FakeTranslationService`/
/// `FoundationModelsTranslationService` themselves.
public protocol TranslationService: TranslationOnlyService {
    /// A short summary of `text` in `targetLanguage`, roughly
    /// `sentenceCount` sentences — the design handoff's 1e list-row summary
    /// treatment ("英文行は...日本語要約2行"). `sentenceCount` is a
    /// request, not a guarantee; engines should treat it as a strong hint
    /// about desired length rather than a hard constraint the caller can
    /// rely on for layout.
    func summarize(_ text: String, targetLanguage: TranslationLanguage, sentenceCount: Int) async throws -> String

    /// A short, **unlabeled** summary of `text` — no fixed output structure,
    /// unlike `summarize` (whose `FoundationModelsTranslationService`
    /// implementation always requests a 3-part ■要約/■伝えたいこと/
    /// ■アクション structure). Exists solely as the "map" half of
    /// `summarizeLongText`'s map-reduce over long input: each
    /// `TranslationChunker` piece is compressed to about `sentenceCount`
    /// plain sentences here, and only the final, combined "reduce" step
    /// calls `summarize` — exactly once — for the real structured output.
    ///
    /// Task #122: before this method existed, `summarizeLongText` called the
    /// *structured* `summarize` once per chunk. For a multi-chunk email that
    /// produced the 3-part structure once per chunk, all joined together —
    /// and fed that already-■-labeled text back into one more structured
    /// `summarize` call as its literal input. A real-device report showed
    /// exactly the resulting failure: the labeled structure repeated, and
    /// the model — primed by ■-labeled text already present in its own
    /// input — went on to echo `summarizeInstructions`'s own label-
    /// definition wording verbatim after the real answer. Splitting the
    /// map (plain) from the reduce (structured, exactly once) removes the
    /// repeated-structure input that triggered this; `SummaryOutputSanitizer`
    /// (`OtegamiCore`) is the remaining defense-in-depth layer.
    func summarizePlain(_ text: String, targetLanguage: TranslationLanguage, sentenceCount: Int) async throws -> String

    /// Task #153 (スレッド全体のAI要約): the single, structured "reduce" call
    /// behind `summarizeThread`'s map-reduce (this method's own doc comment)
    /// — always produces exactly two `■`-prefixed sections, `■経緯`
    /// (chronological narrative) then `■現状` (current state), unlike
    /// `summarize`'s single-message 3-part ■要約/■伝えたいこと/■アクション
    /// shape. A sibling of `summarize`, not an overload of it: the two
    /// produce genuinely different output structures for genuinely
    /// different inputs (one message vs. a whole thread's digest), and
    /// giving them distinct names keeps a caller's intent explicit at every
    /// call site rather than relying on which overload got resolved.
    func summarizeThreadDigest(_ text: String, targetLanguage: TranslationLanguage) async throws -> String
}

extension TranslationService {
    /// Most callers want a 2-sentence summary (the 1e list-row treatment) —
    /// this default keeps call sites from repeating that number.
    public func summarize(_ text: String, targetLanguage: TranslationLanguage) async throws -> String {
        try await summarize(text, targetLanguage: targetLanguage, sentenceCount: 2)
    }

    /// A `summarize` that stays safe for arbitrarily long mail bodies —
    /// design-phase-3's real-device finding: `summarize` on a long English
    /// mail could hit the same context-window overflow `translate` did
    /// (`TranslationChunker`'s doc comment), and `MessageView`'s "AI要約"
    /// button has no paragraph-alignment requirement forcing it through
    /// `MessageTranslator`'s cache the way message translation does, so
    /// this lives here as a plain protocol extension any conformer gets for
    /// free. Map-reduce for oversized input: summarize each
    /// `TranslationChunker` piece to about one sentence via the *unlabeled*
    /// `summarizePlain` (Task #122 — see its doc comment for why the map
    /// step must not be the structured, 3-part `summarize`), then always
    /// run the combined partial summaries through exactly one final
    /// `summarize` call for the real 3-part structure. Short input (the
    /// common case) is a single, un-chunked `summarize` call, unchanged
    /// from before this existed.
    public func summarizeLongText(_ text: String, targetLanguage: TranslationLanguage, sentenceCount: Int = 2) async throws -> String {
        guard text.count > TranslationChunker.defaultMaxChunkLength else {
            return try await summarize(text, targetLanguage: targetLanguage, sentenceCount: sentenceCount)
        }

        let chunks = TranslationChunker.chunk(text)
        var partialSummaries: [String] = []
        partialSummaries.reserveCapacity(chunks.count)
        for chunk in chunks {
            partialSummaries.append(try await summarizePlain(chunk, targetLanguage: targetLanguage, sentenceCount: 1))
        }
        let combined = partialSummaries.joined(separator: " ")
        // Task #122: always run `combined` through the structured
        // `summarize` — even when there was only a single chunk. Before
        // this fix, a single-chunk input returned `combined` (that one
        // chunk's own already-structured `summarize` output) directly,
        // skipping this call; now that the map step is unlabeled, skipping
        // it here would return a summary with no ■要約/■伝えたいこと/
        // ■アクション structure at all, breaking `summarizeLongText`'s
        // contract that its output always has that shape (same as the
        // un-chunked short-input path above). This combined text is itself
        // short (a handful of sentences) even for a huge source email, so
        // it's always safely under the chunk threshold — no risk of *this*
        // call recursing into another split.
        return try await summarize(combined, targetLanguage: targetLanguage, sentenceCount: sentenceCount)
    }

    /// Task #153 (スレッド全体のAI要約): a whole-thread digest, safe for an
    /// arbitrarily long thread — the same map-reduce shape
    /// `summarizeLongText` uses for a single long message, but reducing
    /// through `summarizeThreadDigest` (■経緯/■現状, 2 parts) instead of
    /// `summarize` (■要約/■伝えたいこと/■アクション, 3 parts). `text` is
    /// expected to already be the `"[<date>] <sender>: <newText>"`-per-line
    /// thread digest input (`ThreadDetailView`'s own builder) — this method
    /// only handles the chunking, not building that input.
    ///
    /// Short input (the common case: most threads' combined new-text easily
    /// fits under `TranslationChunker.defaultMaxChunkLength`) is a single,
    /// un-chunked `summarizeThreadDigest` call. Longer input chunks via
    /// `TranslationChunker.chunk` and maps each chunk through the existing
    /// unlabeled `summarizePlain` (reused as-is, no changes needed there —
    /// same Task #122 rationale `summarizeLongText` already documents: the
    /// map step must never be a structured call, or the structure gets
    /// echoed back as input to the reduce step), then reduces the joined
    /// partial summaries through exactly one final `summarizeThreadDigest`
    /// call. `sentenceCount: 2` (not `summarizeLongText`'s `1`) for the map
    /// step: a thread digest's reduce step wants noticeably more raw detail
    /// per chunk than a single message's summary does, since it's
    /// reassembling a multi-message narrative rather than compressing one
    /// message's own text.
    ///
    /// `TranslationChunker.chunk` already prefers splitting at line breaks
    /// (`splitIntoUnits` treats every `"\n"`-terminated line as its own
    /// unit before falling back to sentence punctuation, and only hard-
    /// slices mid-unit when a single unit alone exceeds the chunk budget) —
    /// since this method's input is line-per-message
    /// (`"[date] sender: text"`), a chunk boundary lands between two
    /// messages' lines in the overwhelmingly common case, not mid
    /// `"[date] sender:"` prefix. The only way a boundary could still land
    /// inside that prefix is a single message's own line exceeding
    /// `TranslationChunker.defaultMaxChunkLength` (2000 characters) *before*
    /// its first sentence-ending punctuation or line break — an unusually
    /// long single unbroken message — which `TranslationChunker`'s existing
    /// hard-slice fallback already has to handle for ordinary prose too;
    /// no changes were made to `TranslationChunker` for this method, since
    /// its existing line-preferring behavior already covers the common case
    /// this doc comment's caution was raised against.
    public func summarizeThread(_ text: String, targetLanguage: TranslationLanguage) async throws -> String {
        guard text.count > TranslationChunker.defaultMaxChunkLength else {
            return try await summarizeThreadDigest(text, targetLanguage: targetLanguage)
        }

        let chunks = TranslationChunker.chunk(text)
        var partialSummaries: [String] = []
        partialSummaries.reserveCapacity(chunks.count)
        for chunk in chunks {
            partialSummaries.append(try await summarizePlain(chunk, targetLanguage: targetLanguage, sentenceCount: 2))
        }
        let combined = partialSummaries.joined(separator: " ")
        return try await summarizeThreadDigest(combined, targetLanguage: targetLanguage)
    }
}
