import Foundation

/// Splits a plain-text message body into paragraphs for
/// `TranslationService.translateParagraphs` — pure string logic, no engine
/// involved, so it's identical regardless of which `TranslationService`
/// ends up translating the result.
///
/// A "paragraph" here is a run of non-blank lines separated by one or more
/// blank lines, which is what `HTMLTextExtractor`/quoted-plain-text mail
/// bodies in this codebase already normalize toward (blank-line-separated
/// blocks) — this deliberately doesn't try to be a general-purpose prose
/// splitter (no sentence boundary detection, no heuristics for
/// single-newline-separated paragraphs some clients produce), since the
/// alternative — a paragraph boundary that doesn't match what
/// `MessageBodyRecord.plainText` actually contains — would misalign
/// `MessageTranslationRecord.paragraphs` far worse than an occasional
/// over-long paragraph would.
public enum ParagraphSplitter {
    /// Splits `text` on blank lines, trims surrounding whitespace from each
    /// paragraph, and drops any paragraph that's empty after trimming
    /// (e.g. from three-or-more consecutive blank lines). Returns `[]` for
    /// blank/whitespace-only input.
    public static func split(_ text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { lines in
                lines
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }
}
