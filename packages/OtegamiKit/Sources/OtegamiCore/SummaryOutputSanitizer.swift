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
    public static func sanitize(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard
            let summaryLineIndex = firstLineIndex(ofLabel: summaryLabel, in: lines, from: 0),
            let intentLineIndex = firstLineIndex(ofLabel: intentLabel, in: lines, from: summaryLineIndex + 1),
            let actionLineIndex = firstLineIndex(ofLabel: actionLabel, in: lines, from: intentLineIndex + 1)
        else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let actionContentEnd = firstLineIndex(ofLabel: "■", in: lines, from: actionLineIndex + 1) ?? lines.count

        let summaryContent = content(label: summaryLabel, labelLineIndex: summaryLineIndex, in: lines, contentEnd: intentLineIndex)
        let intentContent = content(label: intentLabel, labelLineIndex: intentLineIndex, in: lines, contentEnd: actionLineIndex)
        let actionContent = content(label: actionLabel, labelLineIndex: actionLineIndex, in: lines, contentEnd: actionContentEnd)

        return """
        \(summaryLabel)
        \(summaryContent)

        \(intentLabel)
        \(intentContent)

        \(actionLabel)
        \(actionContent)
        """
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
