import Foundation

/// Splits a chunk of text into sentence-like units — the smallest retry
/// granularity `MessageTranslator.translateAligned` falls back to when a
/// whole chunk is rejected by the engine's safety guardrails (Task #81,
/// following on from Task #61's chunk-level tolerance: 実機フィードバック
/// 「MakerWorld のメールで翻訳が一部効かない」— a chunk-wide fallback to
/// original text threw away every innocuous sentence sharing a chunk with
/// the one sentence that actually triggered the guardrail).
///
/// A "sentence" here is a run of text up to and including a `.`/`!`/`?`/
/// `。`/`．`/`！`/`？` terminator, or a line break for text with no
/// terminator at all (mirroring `TranslationChunker`'s own
/// `splitIntoUnits`, which this deliberately doesn't share code with —
/// see that type's private method for the near-identical logic — so each
/// stays a simple, independently testable pure function rather than
/// introducing a shared abstraction for what's currently only two ~15-line
/// call sites).
public enum SentenceSplitter {
    /// Splits `text` into sentence-like units, trimming surrounding
    /// whitespace from each and dropping any that are empty after
    /// trimming. Returns `[]` for blank/whitespace-only input, and a
    /// single-element array when `text` contains no terminator or line
    /// break at all (the whole text is "one sentence") — callers use
    /// `count > 1` to tell "splittable further" from "already as small as
    /// it gets".
    public static func split(_ text: String) -> [String] {
        let terminators = CharacterSet(charactersIn: ".!?。．！？")
        var units: [String] = []
        var current = ""

        func flushCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { units.append(trimmed) }
            current = ""
        }

        for character in text {
            current.append(character)
            if character == "\n" {
                flushCurrent()
            } else if character.unicodeScalars.allSatisfy({ terminators.contains($0) }) {
                flushCurrent()
            }
        }
        flushCurrent()
        return units
    }
}
