import Foundation

/// Whether a `TranslationService` can actually translate right now,
/// mirroring the shape of `FoundationModels.SystemLanguageModel
/// .Availability` (`SystemLanguageModel.default.availability`) without
/// leaking that Apple-only type through the protocol boundary — a
/// `FakeTranslationService` or some future non-Apple engine has no
/// `SystemLanguageModel.UnavailableReason` to report, only a reason of its
/// own.
public enum TranslationAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: TranslationUnavailableReason)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Why a `TranslationService` reports `.unavailable`. Named to line up with
/// (but not `import`) `SystemLanguageModel.Availability.UnavailableReason`'s
/// three cases (`deviceNotEligible`/`appleIntelligenceNotEnabled`/
/// `modelNotReady`) — see `FoundationModelsTranslationService.availability`
/// for the mapping. `notSupported` covers everything outside that specific
/// enum (e.g. a hypothetical engine with no on-device model at all).
public enum TranslationUnavailableReason: Sendable, Equatable {
    /// The current device/OS can't run the on-device model at all (e.g.
    /// below the minimum RAM tier Apple Intelligence requires).
    case deviceNotEligible
    /// The device could support it, but the user hasn't turned Apple
    /// Intelligence on in Settings.
    case appleIntelligenceNotEnabled
    /// Eligible and enabled, but the on-device model assets haven't
    /// finished downloading yet.
    case modelNotReady
    /// `AppleTranslationService.ensureLanguagePairSupported`:
    /// `LanguageAvailability.status(from:to:)` reported `.unsupported` for
    /// this specific language pair — this device/OS simply has no NMT model
    /// for it, downloading wouldn't help.
    case languagePairUnsupported
    /// `AppleTranslationService.ensureLanguagePairSupported`:
    /// `LanguageAvailability.status(from:to:)` reported `.supported` (not
    /// `.installed`) — the *only* place this codebase claims "not
    /// downloaded yet" (2026-07-30 real-device log `dd58453`: a
    /// translate-time engine failure unrelated to downloads —empty input,
    /// `TranslationErrorDomain Code=21` — was previously mis-mapped to this
    /// same claim by `AppleTranslationService.mapEngineError`/
    /// `prepareTranslationOrThrow` just because the pack *happened* to also
    /// be undownloaded on a different device; that mapping was removed
    /// because it produced a confidently-wrong diagnosis when the pack was
    /// actually already installed). Never inferred from an engine-call
    /// failure — only from this proactive availability check.
    case languagePackNotDownloaded
    /// Any other reason, carrying a short human-readable explanation —
    /// used by engines (including `FakeTranslationService`, when
    /// configured to simulate unavailability) that don't map onto the
    /// cases above. `userFacingMessage` deliberately does *not* surface
    /// this string to the user (see that property) — it's for logs/tests
    /// only, since callers that reach this case by definition don't have a
    /// specific, trustworthy classification to show.
    case other(String)

    /// A short, Japanese, user-facing explanation — see
    /// `TranslationServiceError.userFacingMessage`'s doc comment for why
    /// this has to be a fixed, curated string per case rather than ever
    /// interpolating an engine's raw error text (2026-07-30 real-device
    /// report: a raw `other(...)` dump reached the user as a garbled,
    /// self-contradictory toast). Deliberately vague about *where* in
    /// Settings to look (`appleIntelligenceNotEnabled`) rather than a fixed
    /// menu path — iOS has moved this menu across versions before
    /// (2026-07-30 correction), so any hardcoded path would eventually go
    /// stale.
    public var userFacingMessage: String {
        switch self {
        case .deviceNotEligible:
            "この端末は翻訳機能に対応していません"
        case .appleIntelligenceNotEnabled:
            "Apple Intelligenceが無効です。設定アプリで有効にしてください"
        case .modelNotReady:
            "翻訳モデルの準備がまだ完了していません。しばらくしてからお試しください"
        case .languagePairUnsupported:
            "この言語の組み合わせは翻訳に対応していません"
        case .languagePackNotDownloaded:
            "翻訳用の言語データが未ダウンロードです"
        case .other:
            // 2026-07-30 (実機フィードバック): これ単体では自然な文だが、
            // 表示側 (`MessageDetailFooterToolbar.translateFootnote`) が
            // 「翻訳に失敗しました: 」という prefix を付けて表示するため、
            // ここでも同じ書き出しにすると「翻訳に失敗しました: 翻訳に
            // 失敗しました…」という二重表示になる実機バグがあった —
            // prefix 側だけが「失敗した」という前置きを担い、ここは
            // 続く具体的な案内 (「時間をおいて再試行してください」) だけ
            // を返す。
            "時間をおいて再試行してください"
        }
    }
}
