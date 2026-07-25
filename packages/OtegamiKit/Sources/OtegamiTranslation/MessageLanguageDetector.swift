import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Detects a message's dominant language, cheaply enough to run inline
/// during body sync (`SyncEngine.BodyFetcher`) rather than lazily when a
/// list row scrolls into view. Deliberately *not* part of
/// `TranslationService`: this doesn't need an LLM (the task's own framing —
/// "`NLLanguageRecognizer` が確実で軽量。Foundation Models を使うまでもない"
/// — a full `LanguageModelSession` round-trip per message would cost orders
/// of magnitude more time and (for the on-device model) energy than
/// `NLLanguageRecognizer`'s few milliseconds), and it needs to work
/// (synchronously, no `await`) even when Apple Intelligence/
/// `FoundationModels` is unavailable — language detection and translation
/// have independent availability, not a shared one.
///
/// Wrapped in `#if canImport(NaturalLanguage)` rather than split into its
/// own target: `NaturalLanguage` has shipped on every Apple OS version this
/// package targets (unlike `FoundationModels`), so gating at the file level
/// keeps a hypothetical Linux build of this target compiling (to nothing)
/// instead of failing, without the ceremony of a whole extra target for one
/// small file.
public enum MessageLanguageDetector {
    #if canImport(NaturalLanguage)
    /// How much of a message body to feed the recognizer.
    /// `NLLanguageRecognizer` wants a representative sample, not the whole
    /// document — capping this keeps detection O(1) instead of O(body
    /// size) for the pathological "10MB pasted log file" message, per the
    /// task's "長文・巨大メールでのタイムアウトやメモリの挙動" concern.
    static let maxSampleLength = 2000

    /// The BCP-47 language code (e.g. `"en"`, `"ja"`) `NLLanguageRecognizer`
    /// is most confident about, or `nil` if `text` is too short/ambiguous
    /// (symbols-only, a couple of words, ...) for it to commit to one —
    /// `MessageRecord.detectedLanguage` stays `nil` in that case rather
    /// than recording a guess a caller might treat as confident.
    public static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let sample = String(trimmed.prefix(maxSampleLength))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage else { return nil }
        return language.rawValue
    }

    /// Convenience for the common case this feature actually acts on
    /// ("英語のメール" — the design handoff's differentiator): `true` only
    /// when `detect` is confident the text is English, `false` for every
    /// other detected language *and* for "couldn't tell" — a caller that
    /// wants to distinguish "confidently not English" from "unknown" should
    /// use `detect` directly.
    public static func isEnglish(_ text: String) -> Bool {
        detect(text) == "en"
    }
    #endif
}
