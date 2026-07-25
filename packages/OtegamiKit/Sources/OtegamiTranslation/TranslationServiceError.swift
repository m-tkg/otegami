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
    /// The engine attempted the translation and failed (guardrail
    /// violation, context window exceeded, decoding failure, transient
    /// engine error, ...). `message` is a short, already-localized-enough-
    /// for-a-log-line description of what went wrong.
    case failed(message: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            "Translation unavailable: \(reason)"
        case .failed(let message):
            "Translation failed: \(message)"
        }
    }
}
