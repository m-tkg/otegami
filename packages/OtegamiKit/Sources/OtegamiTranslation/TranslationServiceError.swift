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
    /// 2026-07-30 (Phase 5続報、実機フィードバック f7b623f 適用後の再報告):
    /// エンジンへ渡した入力自体が「翻訳しようがない」ために失敗した — 空/
    /// 空白/不可視文字だけ (`MessageTranslator.noTranslatableContentMessage`
    /// 経由)、または `Translation.TranslationError.unableToIdentifyLanguage`
    /// /`.nothingToTranslate` (`AppleTranslationService.mapEngineError`)。
    /// `.failed`から独立させた理由: 前回の修正 (9e74419) は「HTML抽出が
    /// `MessageTranslator.noTranslatableContentMessage`という**特定の文言**
    /// を返したら plain へフォールバックする」という文字列比較に頼っており、
    /// 同じ根本原因 (実質空の入力) がAppleの翻訳エンジン側で
    /// `unableToIdentifyLanguage`という**別の**エラーとして表面化した実機
    /// ケース (「翻訳元の言語を判定できませんでした」) を素通りしてしまった
    /// — 将来また新しい文言のバリエーションが増えてもすり抜けないよう、
    /// 「入力不足系の失敗かどうか」をケース (型) で判定できるようにする。
    case insufficientInput(message: String)

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
        case .insufficientInput(let message):
            "Translation input insufficient: \(message)"
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

    /// `MessageTranslator.translateAligned`'s outer catch, and (via
    /// `MessageTranslationState.insufficientInput`) `MessageView
    /// .requestTranslation`'s HTML→plain fallback decision — a
    /// type/case-level check rather than comparing rendered message
    /// strings (see `.insufficientInput`'s own doc comment for why the
    /// prior string-comparison approach broke on exactly this failure
    /// mode).
    public var isInsufficientInput: Bool {
        if case .insufficientInput = self { return true }
        return false
    }

    /// A short, Japanese, user-facing explanation of *why* this failed —
    /// `errorDescription` above stays an English, log-oriented description
    /// (existing behavior, unchanged); this is what `apps/Otegami`'s
    /// `MessageDetailFooterToolbar`'s `translateButton` footnote (Task #88;
    /// formerly `TranslationFloatingButton`, Task #55 renamed these from
    /// `TranslationBar`/`AISummaryBar`)/`MessageView`'s summary sheet
    /// footnote should actually show a user, since both
    /// `MessageTranslationState.failed`/`MessageSummaryState.failed` only
    /// carry a `String` (not this `Error` itself — see
    /// `MessageTranslationState`'s doc comment for why), so the category
    /// (長すぎる/モデル利用不可/その他) has to be captured in the message
    /// text at the point this error is caught, not reconstructed later.
    public var userFacingMessage: String {
        switch self {
        case .unavailable(let reason):
            // 2026-07-30 訂正: 以前はここで `reason` を生のまま文字列補間して
            // いた (`other("...")` がそのまま画面に出る、読解不能かつ内容が
            // 誤診断のケースがあった実機報告) — `TranslationUnavailableReason
            // .userFacingMessage`側でケースごとに管理された短い日本語文言を
            // 使う。
            return reason.userFacingMessage
        case .tooLong:
            return "本文が長すぎるため処理できませんでした"
        case .failed(let message):
            return message
        case .insufficientInput(let message):
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
