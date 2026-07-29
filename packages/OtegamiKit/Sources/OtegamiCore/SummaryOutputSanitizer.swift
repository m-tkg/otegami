import Foundation

/// Defends the "AI要約" feature's displayed output against
/// `FoundationModelsTranslationService.summarize`'s on-device model
/// occasionally producing more than the requested single ■要約/■伝えたいこと/
/// ■アクション block.
///
/// Task #122: a real-device report (screenshots) showed two related
/// failures, both of which land as "extra text after the real answer" from
/// this parser's point of view:
///  - (a) the correct 3-part block, followed by a second — sometimes
///    garbled — repetition of the same three labels.
///  - (b) the correct 3-part block, followed by
///    `summarizeInstructions`'s own label-definition wording echoed
///    verbatim (e.g. `"■要約 — in about 2 short sentences, describe..."`),
///    with the labels' real answers restated yet again after that.
/// Both start with a *complete, correct* first block — the bug is purely in
/// what comes after it. `sanitize(_:)` finds that first complete block and
/// discards everything from the start of whatever `■`-prefixed line comes
/// next (a repeated label, a leaked instruction fragment — both begin with
/// `■`, matching this parser's own label prefixes), so the caller only ever
/// sees the one real answer.
///
/// This is a pure string function specifically so it's unit-testable without
/// `FoundationModels`/Apple Intelligence (only reachable, iOS/macOS 26+,
/// from `OtegamiTranslationFoundationModelsTests`, which skips itself on
/// hardware without Apple Intelligence — see that suite's doc comment) and
/// reusable if a future engine needs the same defense — hence living in
/// `OtegamiCore` (Task #122's implementation note) rather than inside
/// `OtegamiTranslationFoundationModels` itself.
public enum SummaryOutputSanitizer {
    public static let summaryLabel = "■要約"
    public static let intentLabel = "■伝えたいこと"
    public static let actionLabel = "■アクション"

    /// Returns only the first complete `summaryLabel` → `intentLabel` →
    /// `actionLabel` block found in `text` (each part trimmed of
    /// surrounding whitespace), reassembled with a blank line between parts
    /// — the same shape `FoundationModelsTranslationService
    /// .summarizeInstructions` asks the model for. Anything before the
    /// first `summaryLabel` line, and anything from the next `■`-prefixed
    /// line onward (after the three parts are found), is discarded.
    ///
    /// Falls back to `text` trimmed of surrounding whitespace, unchanged,
    /// when the three labels can't all be found in order — rather than
    /// guess at a malformed response's structure, a summary this broken
    /// should surface as-is (so it's visible for debugging) instead of
    /// being silently emptied or partially reassembled.
    ///
    /// Task #153: now a thin wrapper over `sanitize(_:labels:)` — see that
    /// method's doc comment for the generalized logic (unchanged behavior,
    /// same 8 test cases in `SummaryOutputSanitizerTests` still pass).
    public static func sanitize(_ text: String) -> String {
        sanitize(text, labels: [summaryLabel, intentLabel, actionLabel])
    }

    /// Task #153 (スレッド全体のAI要約、■経緯/■現状の2ラベル出力): generalizes
    /// `sanitize(_:)`'s 3-label logic to an arbitrary, ordered `labels` list
    /// — the whole-thread digest wants exactly two labels (■経緯/■現状) in
    /// place of the single-message 3-part ■要約/■伝えたいこと/■アクション,
    /// and duplicating this parser's logic a second time for a different
    /// label count would just be a second place for Task #122/#148's
    /// hard-won anti-repetition/anti-leak fixes to drift out of sync.
    ///
    /// For each label in `labels`, finds its line index (in order, each
    /// search starting after the previous label's own line — mirrors the
    /// original's `from: summaryLineIndex + 1`-style chaining) and falls
    /// back to `text` trimmed of surrounding whitespace, unchanged, the
    /// moment any label can't be found — same "don't guess at a malformed
    /// response's structure" fallback semantics as `sanitize(_:)` always
    /// had. Each label's content-end is the next `■`-prefixed line found
    /// after it, or (if none) the next label's own line index — falling
    /// back to `lines.count` for the last label — exactly the `zip
    /// (labelIndices, labelIndices.dropFirst() + [lines.count])` pairing the
    /// doc comment on this method's call sites describes: this is the
    /// Task #148 fix (a repeated/leaked `■`-prefixed line sandwiched
    /// *between* two real labels must not be swallowed into the preceding
    /// label's content) generalized over however many labels are given,
    /// still using the label-agnostic `content(label:labelLineIndex:in:
    /// contentEnd:)`/`trailingContent(afterLabel:in:)` primitives unchanged.
    /// Reassembles with the same blank-line-between-parts convention
    /// `sanitize(_:)` always used.
    public static func sanitize(_ text: String, labels: [String]) -> String {
        let lines = text.components(separatedBy: "\n")

        var labelIndices: [Int] = []
        var searchStart = 0
        for label in labels {
            guard let index = firstLineIndex(ofLabel: label, in: lines, from: searchStart) else {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            labelIndices.append(index)
            searchStart = index + 1
        }

        let nextBoundaries = Array(labelIndices.dropFirst()) + [lines.count]
        let parts = zip(labels, zip(labelIndices, nextBoundaries)).map { label, indices -> String in
            let (labelLineIndex, nextBoundary) = indices
            let contentEnd = firstLineIndex(ofLabel: "■", in: lines, from: labelLineIndex + 1) ?? nextBoundary
            let partContent = content(label: label, labelLineIndex: labelLineIndex, in: lines, contentEnd: contentEnd)
            return "\(label)\n\(partContent)"
        }
        return parts.joined(separator: "\n\n")
    }

    /// The index of the first line (at or after `start`) whose
    /// whitespace-trimmed content begins with `label` — e.g. both a clean
    /// `"■要約"` line and a leaked `"■要約 — in about..."` line match
    /// `label: "■要約"`; a bare `label: "■"` search matches any of the
    /// three real labels *or* any other `■`-prefixed line (used to find
    /// where trailing/repeated content starts).
    private static func firstLineIndex(ofLabel label: String, in lines: [String], from start: Int) -> Int? {
        guard start < lines.count, start >= 0 else { return nil }
        for index in start..<lines.count where lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(label) {
            return index
        }
        return nil
    }

    /// A label's content is every line strictly between its own line and
    /// `contentEnd`, plus — defensively — any text trailing the label on
    /// its *own* line once a leaked-instruction-style separator (`" — "`,
    /// `"："`, `": "`, `"-"`) is stripped, in case the label and its answer
    /// ended up on the same line.
    private static func content(label: String, labelLineIndex: Int, in lines: [String], contentEnd: Int) -> String {
        var contentLines: [String] = []
        let trailing = trailingContent(afterLabel: label, in: lines[labelLineIndex])
        if !trailing.isEmpty {
            contentLines.append(trailing)
        }
        if labelLineIndex + 1 < contentEnd {
            contentLines.append(contentsOf: lines[(labelLineIndex + 1)..<contentEnd])
        }
        return contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let sameLineSeparators = [" — ", "—", "：", ": ", "-"]

    private static func trailingContent(afterLabel label: String, in line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(label) else { return "" }
        var remainder = String(trimmed.dropFirst(label.count))
        for separator in sameLineSeparators where remainder.hasPrefix(separator) {
            remainder = String(remainder.dropFirst(separator.count))
            break
        }
        return remainder.trimmingCharacters(in: .whitespaces)
    }
}
