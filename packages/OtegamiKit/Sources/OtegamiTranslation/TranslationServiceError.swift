import Foundation

/// Errors a `TranslationService` conformer throws. Deliberately narrow (two
/// cases) and string-carrying rather than wrapping the underlying engine's
/// own error type — `LanguageModelSession`'s errors, `NSError`s from some
/// future cloud fallback, etc. are all Apple/engine-specific and shouldn't
/// leak through a protocol whose entire point is to let callers stay
/// engine-agnostic. `FoundationModelsTranslationService` maps every
/// `LanguageModelSession` failure into one of these, preserving
/// `error.localizedDescription` as `message` for logging.
public enum TranslationServiceError: Error, Sendable, Equatable, LocalizedError {
    /// The engine can't translate right now — surface the same
    /// `TranslationUnavailableReason` `availability` would have reported,
    /// for a caller that only discovers unavailability by attempting a
    /// call (e.g. a race where availability flipped between the check and
    /// the call).
    case unavailable(TranslationUnavailableReason)
    /// The source text (or, after `ParagraphSplitter`/chunking, one piece
    /// of it) is longer than the engine's context window can accept even
    /// after chunking — reported as its own case (rather than folding into
    /// `.failed`) so a caller can show a specific "本文が長すぎます" message
    /// instead of a generic failure, per design-phase-3's "なぜ失敗したか"
    /// requirement (`docs/translation.md`'s known-limitations section).
    /// `message` carries whatever detail the engine reported (token counts,
    /// when available).
    case tooLong(message: String)
    /// The engine attempted the translation and failed for some other
    /// reason (decoding failure, transient engine error, ...). `message` is
    /// a short, already-localized-enough-for-a-log-line description of
    /// what went wrong.
    case failed(message: String)
    /// Task #61 (実機フィードバック「無害なマーケティングメールなのに
    /// "The model's safety guardrails were triggered." で翻訳全体が失敗
    /// する」): Apple Foundation Models のガードレール (`LanguageModelError
    /// .guardrailViolation`/旧`LanguageModelSession.GenerationError
    /// .guardrailViolation` — `FoundationModelsTranslationService
    /// .mapEngineError`のdoc comment参照) は実際には無害な文面でも誤発動
    /// することが実機で確認された。`.failed`から独立したケースにしたのは、
    /// `MessageTranslator.translateAligned`がこのケースだけをチャンク単位
    /// で「原文のまま残して続行」の対象として識別できるようにするため —
    /// 他の`.failed`要因 (デコード失敗など) は従来どおりチャンク1つの失敗が
    /// 全体を失敗させる。
    case contentBlocked(message: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            "Translation unavailable: \(reason)"
        case .tooLong(let message):
            "Text too long: \(message)"
        case .failed(let message):
            "Translation failed: \(message)"
        case .contentBlocked(let message):
            "Translation content blocked: \(message)"
        }
    }

    /// `MessageTranslator.translateAligned`'s per-chunk tolerance check —
    /// named as a predicate (not a `switch` inline at each call site) so
    /// that check reads as intent ("was this chunk's failure a guardrail
    /// misfire?") rather than pattern-matching noise.
    public var isContentBlocked: Bool {
        if case .contentBlocked = self { return true }
        return false
    }

    /// A short, Japanese, user-facing explanation of *why* this failed —
    /// `errorDescription` above stays an English, log-oriented description
    /// (existing behavior, unchanged); this is what `apps/Otegami`'s
    /// `TranslationFloatingButton`'s footnote/`MessageView`'s summary sheet
    /// footnote (Task #55 renamed these from `TranslationBar`/`AISummaryBar`)
    /// should actually show a user, since both
    /// `MessageTranslationState.failed`/`MessageSummaryState.failed` only
    /// carry a `String` (not this `Error` itself — see
    /// `MessageTranslationState`'s doc comment for why), so the category
    /// (長すぎる/モデル利用不可/その他) has to be captured in the message
    /// text at the point this error is caught, not reconstructed later.
    public var userFacingMessage: String {
        switch self {
        case .unavailable(let reason):
            return "この端末では翻訳を利用できません（\(reason)）"
        case .tooLong:
            return "本文が長すぎるため処理できませんでした"
        case .failed(let message):
            return message
        case .contentBlocked:
            // Task #61: this case only ever reaches a user as the *whole*
            // translation's failure when every single chunk hit it
            // (`MessageTranslator.translateAligned`'s all-blocked branch) —
            // a partial hit is tolerated silently (per-chunk original text
            // kept, surfaced later as a modest "一部の文は翻訳できません
            // でした" note via `MessageTranslationRecord
            // .hasPartiallyBlockedContent`, not this message).
            return "翻訳できませんでした（モデルの安全機構が本文をブロックしました）"
        }
    }
}
