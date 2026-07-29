import Foundation
import FoundationModels
import OtegamiTranslation

/// The real, on-device `TranslationService` — backed by
/// `FoundationModels.LanguageModelSession` (Apple's on-device LLM, iOS/
/// macOS 26+, "Apple Intelligence"). This is the only file in the codebase
/// that imports `FoundationModels`; everything else talks to the
/// `TranslationService` protocol (`OtegamiTranslation`) so a build without
/// this framework (an older SDK, `FakeTranslationService`-only tests) never
/// needs to know it exists.
///
/// **API surface, verified against the actual SDK** (not from memory —
/// `docs/translation.md`'s "実装メモ" section records how):
///  - `SystemLanguageModel.default.availability` is a synchronous
///    `@available(iOS 26.0, macOS 26.0, *)` property returning
///    `.available` or `.unavailable(UnavailableReason)`, where
///    `UnavailableReason` is `.deviceNotEligible` /
///    `.appleIntelligenceNotEnabled` / `.modelNotReady` — mapped 1:1 onto
///    `TranslationUnavailableReason` below.
///  - `LanguageModelSession(model:instructions:)` (also iOS/macOS 26+) is
///    the session constructor; `session.respond(to:options:)` awaits a
///    complete `Response<String>` (`.content` is the text),
///    `session.streamResponse(to:options:)` returns an `AsyncSequence`
///    whose elements are cumulative **snapshots of the whole response so
///    far** (`snapshot.content`), not deltas — confirmed by an actual
///    on-device run (see doc comment on `translateStream` below), which is
///    why `TranslationService.translateStream`'s own contract says the
///    same thing.
///
/// One `LanguageModelSession` per call (not one shared/reused session):
/// `LanguageModelSession` only supports one in-flight request at a time
/// (`LanguageModelSession.Error.concurrentRequests`) and carries
/// conversation history forward automatically, neither of which this type
/// wants — translating message A shouldn't be blocked by message B's
/// in-flight translation, and two unrelated messages' translations
/// shouldn't share context. The cost is losing session-level prewarming;
/// not worth the shared-mutable-state complexity for mail-sized requests.
@available(iOS 26.0, macOS 26.0, *)
public struct FoundationModelsTranslationService: TranslationService {
    private let model: SystemLanguageModel

    /// `model` defaults to `.default` (Apple's general-purpose on-device
    /// model); overridable for a future use-case-specific model
    /// (`SystemLanguageModel.UseCase`) without changing every call site.
    public init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    public var availability: TranslationAvailability {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: Self.mapUnavailableReason(reason))
        }
    }

    public func translate(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) async throws -> String {
        try requireAvailable()
        let session = makeSession(from: source, to: target)
        do {
            let response = try await session.respond(to: text, options: Self.translationOptions)
            return response.content
        } catch {
            throw Self.mapEngineError(error)
        }
    }

    public func translateParagraphs(_ paragraphs: [String], from source: TranslationLanguage, to target: TranslationLanguage) async throws -> [String] {
        guard !paragraphs.isEmpty else { return [] }
        try requireAvailable()

        // See the type's doc comment: one fresh session per paragraph, not
        // one shared session fed all paragraphs in sequence — keeps each
        // paragraph's translation independent of the others' (no
        // accumulated conversation context to bias later paragraphs) and
        // trivially safe to eventually parallelize.
        var results: [String] = []
        results.reserveCapacity(paragraphs.count)
        for paragraph in paragraphs {
            let session = makeSession(from: source, to: target)
            do {
                let response = try await session.respond(to: paragraph, options: Self.translationOptions)
                results.append(response.content)
            } catch {
                throw Self.mapEngineError(error)
            }
        }
        return results
    }

    /// Verified end to end on-device (not just compiled): iterating
    /// `session.streamResponse(to:)` for an English→Japanese sentence
    /// yielded 18 snapshots, each one the *entire* translation-so-far
    /// (`"そのミーティング"`, then `"そのミーティングは"`, ...,
    /// finishing at the complete sentence) — never a standalone delta like
    /// `"は"`. `translateStream` below simply forwards each snapshot's
    /// `.content` as-is, which is why callers must render (not append) the
    /// latest yielded element.
    public func translateStream(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try requireAvailable()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let session = makeSession(from: source, to: target)
                do {
                    let stream = session.streamResponse(to: text, options: Self.translationOptions)
                    for try await snapshot in stream {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapEngineError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func summarize(_ text: String, targetLanguage: TranslationLanguage, sentenceCount: Int) async throws -> String {
        try requireAvailable()
        let session = LanguageModelSession(model: model, instructions: Self.summarizeInstructions(targetLanguage: targetLanguage, sentenceCount: sentenceCount))
        do {
            let response = try await session.respond(to: text, options: Self.summarizeOptions)
            return response.content
        } catch {
            throw Self.mapEngineError(error)
        }
    }

    // MARK: - Session/options

    private func makeSession(from source: TranslationLanguage, to target: TranslationLanguage) -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: Self.translationInstructions(from: source, to: target))
    }

    /// Low temperature: translation should be a faithful rendering of the
    /// source text, not a creative rewrite — high-temperature sampling
    /// would make repeated translations of the same paragraph diverge,
    /// which is the opposite of what a cached, re-displayed translation
    /// should do.
    private static let translationOptions = GenerationOptions(temperature: 0.3)
    private static let summarizeOptions = GenerationOptions(temperature: 0.3)

    private static func translationInstructions(from source: TranslationLanguage, to target: TranslationLanguage) -> String {
        """
        You are a professional \(source.displayName)-to-\(target.displayName) translator working on email content.
        Translate the user's message into natural, fluent \(target.displayName), preserving its original meaning, tone, and structure (line breaks, lists, greetings/sign-offs) as closely as possible.
        Output ONLY the translation itself — no preamble, no explanation, no surrounding quotation marks.
        """
    }

    /// Task #62 follow-up: a real-device report said the summary still
    /// read like a recap of the *quoted* reply history rather than what
    /// the current message itself is saying. The input may now be
    /// structured into a "■このメールの新規部分" (this email's own new
    /// text) section and a "■引用されている過去のやり取り (文脈)" (quoted
    /// prior thread, as context) section — see
    /// `MessageView.sourceTextForSummary()`, which builds that structure
    /// via `QuoteStripper.separatingQuotedText`. These two lines tell the
    /// model how to weight them: use the quoted section only to understand
    /// the flow of the conversation, and summarize what the new section
    /// itself communicates — not a re-summary of the quote. Plain
    /// unstructured input (the common case: no quote found, nothing to
    /// separate) is unaffected — there's no section to misweight.
    ///
    /// Task #90 follow-up: the #62 wording ("use the quoted section only
    /// to understand the flow") still left room for the model to lean on
    /// the quote when the new section was short — a real-device report
    /// said summaries could *still* read as a recap of past quoted
    /// content. Added an explicit prohibition ("must not") instead of a
    /// soft preference, plus a fallback instruction for the genuinely
    /// short-new-section case (a one-line "了解です" reply): describe what
    /// *this* message did in response to the thread, rather than either
    /// padding out a one-liner or falling back to summarizing the quote.
    ///
    /// Task #97 follow-up: a real-device report said summaries *narrated
    /// events out of order* — the output described the new reply first,
    /// then belatedly mentioned the quoted history, even though the quote
    /// is chronologically *earlier* than the reply sitting on top of it.
    /// Two changes, both required together (see
    /// `SummaryInputBuilder`'s doc comment for the input-side half):
    ///  - `SummaryInputBuilder.build` now presents the quoted section
    ///    *first* and the new section *second*, so input order already
    ///    matches chronological (and desired narration) order — the
    ///    section labels below were reworded to match
    ///    (`newTextSectionLabel`/`quotedTextSectionLabel`).
    ///  - This instruction now spells out the *output* shape explicitly
    ///    instead of only constraining which section is the "main
    ///    subject": open with a single short context sentence derived from
    ///    the quoted section (only when a quoted section is present),
    ///    then describe the new reply. This still isn't "summarize the
    ///    quote" — the #90 prohibition on making the quote the main
    ///    subject, and the #90 short-reply fallback, are unchanged below
    ///    — it only fixes which one is mentioned *first* in the output.
    ///
    /// Task #102 follow-up: a real-device repro (deeply-nested reply chain,
    /// short new reply on top) showed the #97 "at most one short context
    /// sentence" wording wasn't holding the line — the model still spent
    /// most of the output retelling the quoted messages one by one, each
    /// with its own date/time, and the actual new reply was squeezed into
    /// a single closing sentence. Two changes:
    ///  - The output is now a fixed 3-part **labeled** structure
    ///    (■要約/■伝えたいこと/■アクション) rather than free-form prose —
    ///    giving the "content summary" part an explicit boundary (its own
    ///    label, its own sentence budget) makes it much harder for a
    ///    quoted-message recap to silently expand and crowd it out, and
    ///    the other two parts (intent/tone, requested action) are
    ///    information a free-form summary was never asked for and so
    ///    tended to omit.
    ///  - The single most literal cause of the repro's failure —
    ///    per-message retelling with dates/times — is now an explicit,
    ///    named prohibition ("never mention dates or times", "never
    ///    narrate quoted messages one by one") instead of being implied by
    ///    "at most one context sentence"; the older wording left room for
    ///    the model to decide a *long* single sentence covering multiple
    ///    quoted messages still satisfied "one sentence".
    ///
    /// `sentenceCount` now scopes only the ■要約 part (the content summary)
    /// — ■伝えたいこと and ■アクション are always short (about one sentence
    /// each) regardless of the caller's requested length, since they're
    /// fixed-shape facts (intent/tone; required action or "特になし") rather
    /// than content that scales with the source text's length. See
    /// `TranslationService.summarize`'s doc comment for the "hint, not a
    /// guarantee" framing this still follows.
    private static func summarizeInstructions(targetLanguage: TranslationLanguage, sentenceCount: Int) -> String {
        """
        Summarize the user's email content in \(targetLanguage.displayName), as exactly this 3-part labeled structure — three labels below, each on its own line, each followed by its own content on the next line(s). Do not add any other section, heading, preamble, or explanation, and do not omit any of the three labels even when a part's content is minimal.

        ■要約
        (content summary goes here)

        ■伝えたいこと
        (sender's intent/tone goes here)

        ■アクション
        (requested action, or 特になし, goes here)

        The input sometimes contains two labeled sections: "■これは過去のやり取り (文脈参照用)" (quoted history from the prior thread, given only as context) and "■これが今回届いた返信 (要約対象)" (this email's own new text — the thing to summarize). All three output parts below describe the NEW reply section; the quoted section is background only, never itself the subject of any part.

        ■要約 — in about \(sentenceCount) short sentence\(sentenceCount == 1 ? "" : "s"), describe what this email's own new reply says. This is the main part and its primary subject must always be the new reply, never the quoted history. If — and only if — understanding the reply genuinely requires it, you may open with at most one short subordinate clause referencing the quoted history (e.g. "〜の件について、"); otherwise skip any reference to the quoted history entirely. Regardless of how many messages the quoted history contains, you must NEVER retell it as a sequence of past messages, and you must NEVER mention dates, times, or phrases like "〜さんが「…」と返信し" that narrate an individual quoted message — that narration style is forbidden even inside the single permitted subordinate clause. If the new reply is very short (e.g. just a greeting or a one-line acknowledgment like "了解です"/"承知しました"), do not pad it out and do not fall back to summarizing the quote instead — state briefly what this reply did in response to the thread (e.g. "見積もりの件を了承する返信" rather than a recap of the quoted estimate itself).
        ■伝えたいこと — in about one sentence, describe the sender's intent and tone in writing the new reply (e.g. お礼を伝えたい、確認を求めている、丁寧な／カジュアルな調子など). This is not a repeat of ■要約's content — it's what the message is trying to accomplish, not what it says.
        ■アクション — state in about one sentence what action, if any, the new reply asks the recipient to take (a reply, a confirmation, scheduling, a decision, providing information, etc.). If the new reply asks for nothing, output exactly "特になし" and nothing else for this part.

        When there are no such labeled input sections (no quoted history at all), apply the same three parts to the whole text as given.
        Output ONLY the 3-part structure above — no preamble, no explanation, no text before ■要約 or after the ■アクション content.
        """
    }

    // MARK: - Error/availability mapping

    private func requireAvailable() throws {
        guard case .available = availability else {
            guard case .unavailable(let reason) = availability else {
                throw TranslationServiceError.unavailable(.other("unknown"))
            }
            throw TranslationServiceError.unavailable(reason)
        }
    }

    private static func mapUnavailableReason(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> TranslationUnavailableReason {
        switch reason {
        case .deviceNotEligible:
            .deviceNotEligible
        case .appleIntelligenceNotEnabled:
            .appleIntelligenceNotEnabled
        case .modelNotReady:
            .modelNotReady
        @unknown default:
            .other("Unrecognized SystemLanguageModel.Availability.UnavailableReason")
        }
    }

    /// Most `LanguageModelSession` failures (guardrail violation, decoding
    /// failure, transient engine error, ...) collapse to `.failed` —
    /// `TranslationServiceError`'s whole point is not leaking
    /// `FoundationModels`-specific error cases through the protocol
    /// boundary. `error.localizedDescription` is preserved as the message
    /// for logging/debugging.
    ///
    /// `LanguageModelError.contextSizeExceeded` is the one case pulled out
    /// separately, into `.tooLong` — design-phase-3's real-device finding
    /// (a long English mail's translation failing with an opaque error) is
    /// exactly this case, and `TranslationChunker`'s pre-splitting should
    /// make it rare in practice, but not impossible (its character-based
    /// budget is a heuristic, not an exact token count) — when it does
    /// still happen, the caller should be able to say "本文が長すぎます"
    /// specifically rather than a generic "翻訳に失敗しました", which is
    /// what `.failed` alone can't distinguish.
    private static func mapEngineError(_ error: Error) -> TranslationServiceError {
        // `LanguageModelError` itself is iOS/macOS 27+ (a stricter minimum
        // than this type's own 26+) — this package's deployment target is
        // still 26 (`docs/translation.md`), so this whole type has to be
        // reachable on a 26-only device too; the `#available` check just
        // means a 26-only device never gets the `.tooLong`/`.contentBlocked`
        // special cases below (falls through to the generic `.failed`,
        // exactly like before this mapping existed) rather than failing to
        // compile. `LanguageModelError` is not just OS-gated — the *type*
        // only exists in the iOS/macOS 27 SDK, so `#available` alone is not
        // enough: on CI's older Xcode (26.x SDK) the mere mention of the
        // type fails to compile (`cannot find type 'LanguageModelError' in
        // scope` — exactly the local-Xcode-27-beta vs CI-Xcode-26.5
        // divergence docs/ci.md warns about, this time as a missing type
        // rather than a type-check timeout). Gate at *compile time* on the
        // compiler that ships with the 27 SDK, keeping the runtime
        // `#available` inside.
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, *), let languageModelError = error as? LanguageModelError {
            switch languageModelError {
            case .contextSizeExceeded(let details):
                return .tooLong(message: "\(details.tokenCount)/\(details.contextSize) tokens")
            // Task #61 (実機フィードバック「無害なマーケティングメールなのに
            // "The model's safety guardrails were triggered." で翻訳全体が
            // 失敗する」): ガードレールの誤発動 (実際には安全な文面でも
            // 発生しうる、Apple の既知の挙動) を `.failed` から独立した
            // `.contentBlocked` へ分離 — `MessageTranslator.translateAligned`
            // がこのケースだけをチャンク単位で「原文のまま残して続行」の
            // 対象として識別できるようにする。
            case .guardrailViolation(let violation):
                return .contentBlocked(message: violation.debugDescription)
            default:
                break
            }
        }
        #endif
        // `LanguageModelSession.GenerationError` (26.0+, `deprecated: 27.0`
        // in favor of `LanguageModelError` above) is the shape a call on an
        // iOS/macOS 26-only device (this package's actual deployment floor)
        // still throws — unlike `LanguageModelError`, this type isn't
        // gated behind the 27 SDK, so no `#if compiler`/`#available` guard
        // is needed to reference it, only to catch the (harmless,
        // deprecation-only) case actually being hit on such a device.
        if let generationError = error as? LanguageModelSession.GenerationError, case .guardrailViolation = generationError {
            return .contentBlocked(message: generationError.localizedDescription)
        }
        return .failed(message: error.localizedDescription)
    }
}

/// A plain (not `@available`-annotated) top-level function wrapping
/// `SystemLanguageModel.default.isAvailable` behind a runtime `#available`
/// check — exists so `OtegamiTranslationFoundationModelsTests` (built
/// against this package's iOS 18/macOS 15 floor, since raising the whole
/// package's `platforms:` to iOS/macOS 26 to match
/// `FoundationModelsTranslationService` broke `otegami-relay`'s macOS build
/// — see `docs/translation.md`'s "実装メモ" for that dead end) can gate its
/// `@Suite(.enabled(if:))` trait on real availability without needing the
/// declaration itself to be `@available` (Swift Testing's `@Suite`/`@Test`
/// macros reject an `@available`-marked declaration outright, so this is
/// the one place in this target that *isn't* marked `@available(iOS 26.0,
/// macOS 26.0, *)`; every actual translation call still goes through
/// `FoundationModelsTranslationService`, which is).
public func isFoundationModelsTranslationAvailable() -> Bool {
    if #available(iOS 26.0, macOS 26.0, *) {
        return SystemLanguageModel.default.isAvailable
    }
    return false
}
