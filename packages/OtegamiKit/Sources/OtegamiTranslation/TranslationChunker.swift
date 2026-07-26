import Foundation

/// Splits a single (already paragraph-bounded, see `ParagraphSplitter`)
/// chunk of text further, so no piece handed to
/// `TranslationService.translateParagraphs`/`summarize` risks exceeding the
/// on-device model's context window — `docs/translation.md`'s known
/// limitation: "非常に長い1段落...は理論上これを超える可能性がある". Pure
/// string logic (no engine involved), so it's testable without Apple
/// Intelligence and reusable by both translation and summarization call
/// sites.
///
/// Real-device finding that motivated this (design-phase-3): translation
/// "works for some mail, not others" — the actual cause was long English
/// mail (newsletters, quoted threads) occasionally containing a single
/// paragraph long enough to exceed the measured 8192-token context
/// (`docs/translation.md`'s "実装メモ"), which made
/// `FoundationModelsTranslationService.translateParagraphs` throw and fail
/// the *entire* message's translation, not just that one paragraph. Pre-
/// splitting removes the failure mode instead of just reporting it better.
public enum TranslationChunker {
    /// Conservative character budget per request. `SystemLanguageModel
    /// .default.contextSize` measured 8192 *tokens*, shared between the
    /// system instructions, the input text, and the generated output —
    /// there's no on-device tokenizer exposed to this (non-Apple-only)
    /// target to count exactly, so this uses a deliberately pessimistic
    /// characters-per-token ratio (well under the commonly-cited ~4
    /// chars/token for English, and Japanese output tends to pack more
    /// meaning per token than the English input does, which is the
    /// direction that matters here since output shares the same budget)
    /// rather than trying to be precise. Erring toward smaller chunks costs
    /// a few extra on-device requests; erring toward larger ones risks the
    /// exact failure this type exists to prevent.
    public static let defaultMaxChunkLength = 2000

    /// Splits `text` into pieces no longer than `maxLength` characters,
    /// preferring sentence boundaries so a chunk boundary doesn't fall
    /// mid-sentence when avoidable. Returns `[text]` unchanged when it
    /// already fits — the common case, so callers translating a normal-
    /// length paragraph never pay any splitting cost. Returns `[]` for
    /// empty input.
    public static func chunk(_ text: String, maxLength: Int = defaultMaxChunkLength) -> [String] {
        guard !text.isEmpty else { return [] }
        guard text.count > maxLength else { return [text] }

        let units = splitIntoUnits(text)
        var chunks: [String] = []
        var current = ""

        func flushCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
        }

        for unit in units {
            if unit.count > maxLength {
                // A single "sentence" (or line, if the paragraph has no
                // sentence-ending punctuation at all — e.g. a long
                // unbroken URL or log line) is itself too long — hard-slice
                // it at `maxLength`-character boundaries as a last resort.
                // Whatever was accumulated so far becomes its own chunk
                // first, so this oversized unit's pieces don't get merged
                // with unrelated preceding text.
                flushCurrent()
                chunks.append(contentsOf: hardSlice(unit, maxLength: maxLength))
                continue
            }
            let candidate = current.isEmpty ? unit : current + " " + unit
            if candidate.count > maxLength {
                flushCurrent()
                current = unit
            } else {
                current = candidate
            }
        }
        flushCurrent()
        return chunks
    }

    /// Splits `text` into sentence-like units: everything up to and
    /// including a `.`/`!`/`?`/`。`/`！`/`？`, or a line break for text with
    /// no sentence punctuation at all (so a chunk boundary can still prefer
    /// *a* natural break over an arbitrary character cut, even for
    /// e.g. a long list of one-per-line items).
    private static func splitIntoUnits(_ text: String) -> [String] {
        let terminators = CharacterSet(charactersIn: ".!?。!?")
        var units: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { units.append(trimmed) }
                current = ""
            } else if character.unicodeScalars.allSatisfy({ terminators.contains($0) }) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { units.append(trimmed) }
                current = ""
            }
        }
        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty { units.append(trailing) }
        return units
    }

    /// Last-resort hard split at `maxLength`-character (not byte) boundaries
    /// — used only for a single unit that has no punctuation/line breaks to
    /// split on at all, so this never fragments normal prose.
    private static func hardSlice(_ text: String, maxLength: Int) -> [String] {
        var pieces: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxLength, limitedBy: text.endIndex) ?? text.endIndex
            pieces.append(String(text[start..<end]))
            start = end
        }
        return pieces
    }
}
