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

    // MARK: - HTML/plain-text fallback (Task #203)

    /// Which of a message's two body representations a `detectWithFallback`
    /// call actually used — kept around purely as a diagnostics label
    /// (`docs/translation.md`'s Task #203 section), never anything
    /// content-bearing.
    public enum TextSource: String, Sendable, Equatable {
        case plainText
        case html
    }

    /// A confident language, tagged with which candidate text produced it.
    public struct DetectionOutcome: Sendable, Equatable {
        public let language: String
        public let source: TextSource

        public init(language: String, source: TextSource) {
            self.language = language
            self.source = source
        }
    }

    /// Below this fraction of (non-whitespace) characters being Unicode
    /// letters, a candidate is treated as too markup/symbol-heavy to trust
    /// — even when `NLLanguageRecognizer` is willing to commit to an answer
    /// for it. Two real-device incidents motivate this, not just `detect`
    /// returning `nil`:
    /// - Task #203 (実機フィードバック「HTMLの構造が壊れているメールで
    ///   言語判定に失敗する」— Okta 通知メール): the diagnostics screen's
    ///   character-class breakdown for the failing HTML-extracted sample
    ///   read `letters=14% digits=0% otherSymbols=37%` (the rest
    ///   whitespace/`=`) — a text dominated by markup remnants, not prose.
    /// - Task #159 (実機報告「明らかに英語のOkta通知メールが
    ///   `NLLanguageRecognizer`に`pl`と誤判定される」,
    ///   `MessageView.kickoffTranslationIfNeeded`のdoc comment参照): that
    ///   failure mode was the *opposite* of `nil` — a confident but wrong
    ///   guess. Gating on `detect`'s own confidence alone can't catch that
    ///   case; pre-filtering by how markup-heavy the input looks, before it
    ///   ever reaches the recognizer, can.
    ///
    /// Ordinary English/Japanese prose (even with normal punctuation,
    /// digits, quoted strings) empirically runs 60-90%+ letters once
    /// whitespace is excluded. `0.3` sits well below that range and well
    /// above the `14%` failing sample above — comfortably separating
    /// "markup-contaminated" from "genuine prose" without being so strict
    /// that ordinary short/punctuation-heavy mail (signatures, list
    /// markers, `Re:`-chains) gets rejected.
    static let minLetterRatio = 0.3

    /// Fraction of `text`'s non-whitespace characters that are Unicode
    /// letters. `nil` when there's nothing to measure (empty or
    /// whitespace-only) — the same "can't commit" signal `detect` uses for
    /// blank input.
    static func letterRatio(_ text: String) -> Double? {
        var letters = 0
        var total = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            total += 1
            if CharacterSet.letters.contains(scalar) {
                letters += 1
            }
        }
        guard total > 0 else { return nil }
        return Double(letters) / Double(total)
    }

    /// `true` when `text` is empty/whitespace-only, or its `letterRatio`
    /// falls below `minLetterRatio` — the cheap pre-filter
    /// `detectWithFallback` runs on each candidate before ever calling
    /// `NLLanguageRecognizer` on it.
    static func isTooNoisyToTrust(_ text: String) -> Bool {
        guard let ratio = letterRatio(text) else { return true }
        return ratio < minLetterRatio
    }

    /// Same "letters/digits/equals/other-symbol" percentage breakdown
    /// `TranslationEngine.MessageTranslator.characterClassStats`/
    /// `OtegamiTranslationApple.AppleTranslationService
    /// .characterClassSummary` compute for the *translation* diagnostics
    /// screen — duplicated here rather than shared across the module
    /// boundary (this package sits below both of those; sharing would mean
    /// depending the wrong direction) so a caller of `detectWithFallback`
    /// can log which candidate text produced which outcome (Task #203's
    /// diagnostics requirement) without exposing the text itself, matching
    /// how the existing translation diagnostics screen already stays
    /// content-free.
    public static func characterClassSummary(_ text: String) -> String {
        var letters = 0
        var digits = 0
        var equalsSigns = 0
        var otherSymbols = 0
        var total = 0
        for scalar in text.unicodeScalars {
            total += 1
            if scalar == "=" {
                equalsSigns += 1
            } else if CharacterSet.letters.contains(scalar) {
                letters += 1
            } else if CharacterSet.decimalDigits.contains(scalar) {
                digits += 1
            } else if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                otherSymbols += 1
            }
        }
        guard total > 0 else { return "(empty)" }
        func pct(_ n: Int) -> Int { Int((Double(n) / Double(total) * 100).rounded()) }
        return "letters=\(pct(letters))% digits=\(pct(digits))% equals=\(pct(equalsSigns))% otherSymbols=\(pct(otherSymbols))%"
    }

    /// The fallback both `SyncEngine.BodyFetcher` and `MessageView` need
    /// (Task #203, 実機フィードバック「HTMLの構造が壊れているメールで言語
    /// 判定に失敗する」): tries `plainText` first, then falls back to
    /// `html` (run through `HTMLTextExtractor` here, so both callers can
    /// pass the raw MIME parts instead of duplicating extraction logic
    /// each). `nil` only when neither candidate is usable at all.
    ///
    /// **Why `plainText` first, not `html`** (this task explicitly asked
    /// for the ordering to be justified, not assumed): a genuine MIME
    /// `text/plain` part, when present, is decoded raw text with no
    /// stripping step to get wrong. HTML-derived text always goes through
    /// an extra lossy transform first — and this codebase has hit that
    /// exact failure shape from two independent angles already:
    /// `MailCoreIMAPSession+Mapping.html(from:)`'s doc comment (a
    /// mailcore2 HTML-rendering bug that spliced stray line breaks into
    /// running prose) and `HTMLTextExtractor`'s own tag-stripping (a
    /// best-effort linear scanner, not a real HTML parser, per its doc
    /// comment). Preferring the structurally safer source by default, and
    /// only reaching for the riskier one when the safer one is missing or
    /// fails, is the same "prefer the least lossy input" reasoning
    /// `MailCoreIMAPSession+Mapping.plainText(from:)` already applies one
    /// layer down (real `text/plain` leaf over `plainTextBodyRendering()`
    /// reformatting). This also matches what both call sites already did
    /// before this task (see their prior `resolvePlainText`/
    /// `sourceTextForTranslation` logic) — this function generalizes that
    /// existing preference into an actual retry instead of a one-shot
    /// choice.
    public static func detectWithFallback(plainText: String?, html: String?) -> DetectionOutcome? {
        if let plainText, !isTooNoisyToTrust(plainText), let language = detect(plainText) {
            return DetectionOutcome(language: language, source: .plainText)
        }
        if let html {
            let extracted = HTMLTextExtractor.plainText(fromHTML: html)
            if !isTooNoisyToTrust(extracted), let language = detect(extracted) {
                return DetectionOutcome(language: language, source: .html)
            }
        }
        return nil
    }
    #endif
}
