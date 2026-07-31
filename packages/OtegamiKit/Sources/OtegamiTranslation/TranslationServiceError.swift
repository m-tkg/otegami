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
    /// Task #202 (実機フィードバック: `SupplyGatedRequestQueue`がセッション
    /// 供給を待って諦めた — 「設定要求N回/セッション供給N回、いずれも今回
    /// のリクエストには届きませんでした」でタイムアウトし続ける不具合の
    /// 調査で見つかった、無関係だが併発していた実害): この失敗はそれまで
    /// `.failed(message:)`として投げられていた — `.failed`の
    /// `userFacingMessage`は`message`をそのまま返すため、
    /// `TranslationSessionCoordinator`が診断用に埋め込んだカウンタ入りの
    /// 生文言 ("設定要求14回/セッション供給14回…") がそのまま
    /// `MessageDetailFooterToolbar.translateFootnote`の帯にも表示されて
    /// いた — 長すぎて画面右外へはみ出す実機報告の直接原因。`.failed`から
    /// 独立させたのは、この失敗**だけ**`userFacingMessage`をカウンタ抜きの
    /// 短い定型文に固定するため — `detail`(カウンタを含む診断向けの詳細)は
    /// `errorDescription`/ログ/`TranslationDiagnosticsStore`の「直近の翻訳
    /// 試行」(`error.localizedDescription`経由) にはそのまま残るので、
    /// 診断能力は失っていない。
    case sessionUnavailable(detail: String)

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
        case .sessionUnavailable(let detail):
            "Translation session unavailable: \(detail)"
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
        case .sessionUnavailable:
            // Task #202: 固定の短い定型文 — `detail`(カウンタ入りの診断
            // 情報) はここでは絶対に使わない。上のdoc comment参照。
            // 「翻訳に失敗しました: 」というprefixを表示側が付けるため、
            // `TranslationUnavailableReason.other`と同じ理由で「失敗した」
            // という前置きは重ねず、続く案内だけを返す — 実際、
            // `TranslationUnavailableReason.other`と全く同じ文言
            // (「時間をおいて再試行してください」) をそのまま使っている:
            // どちらも利用者からは同じ「今は無理、後で試して」という
            // アクション不能な失敗であり、区別して伝えるべき固有の情報が
            // 無い (原因の切り分けは診断画面/ログの`detail`側の役目)。
            //
            // `String(localized:)`: このファイルの他の`userFacingMessage`
            // ケースは全て裸のJapanese literal (このpackageは
            // `apps/Otegami/Resources/Localizable.xcstrings`を持たず、
            // `check-localizable-coverage.py`も`apps/Otegami/Sources`しか
            // 見ないため、これまで package 層のこの手のメッセージは意図的に
            // 日本語固定だった — `MessageToolbarPreferences.swift`の
            // doc comment: 「`String(localized:)`で app の string catalog
            // を解決する必要があるものは package でなく app 層に置く」と
            // いう既存判断も同じ理由)。この1件だけ例外的に
            // `String(localized:)`にしたのは、タイムアウト時の帯が実機で
            // 画面外にはみ出した (Task #202の実害) 修正の一部として新規に
            // 書いたメッセージであり、ユーザーへ見せる文言を日本語専用に
            // 固定し直すよりは、`Bundle.main`(既定) 経由でアプリの
            // `Localizable.xcstrings`を引けるようにしておく方が素直なため
            // — キーは`scripts/generate-localizable.py`の辞書に
            // 登録済み (`docs/localization.md`の手順どおり)。`Bundle.main`
            // にこのキーが無い文脈 (`swift test`単体実行など) では
            // Foundationの標準フォールバックどおりキー文字列 (=この
            // 日本語文言) がそのまま返るだけなので、テストの挙動は壊れない。
            return String(localized: "時間をおいて再試行してください")
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
