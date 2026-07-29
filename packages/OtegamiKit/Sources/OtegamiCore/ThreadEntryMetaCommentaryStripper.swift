import Foundation

/// Task #160フォローアップ2 (実機フィードバック「『この返信では〜が述べられ
/// ている』のような説明調(メタ言及)の口調が気になる」): a defense-in-depth
/// backstop for `FoundationModelsTranslationService.summarizeThreadEntry`
/// (the conforming implementation of `TranslationService
/// .summarizeThreadEntry`, `OtegamiTranslationFoundationModels`) — the
/// *primary* fix is tightening that method's own instructions string
/// (`summarizeThreadEntryInstructions`, its doc comment has the full
/// before/after rationale): an explicit ban on message-self-referencing
/// phrasing plus good/bad example pairs. Every other summarize-family
/// instruction in this codebase already has a code-side backstop too
/// (`SummaryOutputSanitizer` for `summarize`'s label structure, Task #122's
/// whole reason for existing) — this mirrors
/// that same "instructions + implementation-side cleanup" pattern for the
/// specific "describing the message about itself" register this feature's
/// own real-device report named.
///
/// **Deliberately narrow, not a generic regex sweep across the whole
/// text**: only a sentence that *itself* opens with one of the message-
/// self-referencing subjects (`openers` below) gets rewritten at all — a
/// sentence without that leading marker is returned completely untouched,
/// even if it happens to contain a word like `"伝えられている"` somewhere
/// in it. That word alone doesn't distinguish meta-commentary about *this
/// message* from the message's own legitimate content — e.g. reporting
/// what a third party said (`"先方からは来月まで待ってほしいと伝えられて
/// いる"`) is real information the map step must not lose (`summarizeThreadEntry`'s
/// own "don't drop numbers/proper nouns/decisions" contract), not a
/// wrapper to strip. Requiring the leading self-referencing opener before
/// touching a sentence at all is what keeps this stripper from over-
/// removing real content — see `ThreadEntryMetaCommentaryStripperTests`'s
/// negative cases, which is exactly what this feature's own spec asked
/// this backstop to avoid ("正規表現ベースで過剰除去しないこと").
public enum ThreadEntryMetaCommentaryStripper {
    /// The message-self-referencing subjects `summarizeThreadEntryInstructions`
    /// explicitly bans as an opener. `"この経緯では"`/`"この経緯は"` were
    /// added for the now-removed `refineThreadEntries` pass (Task #160
    /// フォローアップ3〜4, which described several merged messages at once
    /// rather than a single one, so it talked about "この経緯" rather than
    /// "この返信"/"このメール") — Task #160フォローアップ5 removed that pass
    /// entirely (`TranslationService.summarizeThread`'s doc comment has the
    /// full history), but these two entries are kept here: harmless (no
    /// current caller's output should ever start this way, so they're
    /// simply dead weight rather than a risk) and cheap defensive coverage
    /// if a future feature reintroduces multi-message narration. Order
    /// doesn't currently matter (none is a prefix of another), kept as a
    /// plain list so a future addition is a one-line change.
    private static let openers = [
        "この返信では", "この返信は",
        "このメールでは", "このメールは",
        "このメッセージでは", "このメッセージは",
        "この経緯では", "この経緯は",
    ]

    /// The meta-commentary predicate `summarizeThreadEntryInstructions`
    /// explicitly bans, matched only at a (self-referencing) sentence's own
    /// tail — longer, more specific suffixes listed first so e.g.
    /// `"であることが述べられている"` matches before the shorter
    /// `"が述べられている"` would only partially consume it.
    private static let metaVerbSuffixes = [
        "であることが述べられている", "であることが記載されている",
        "ということが述べられている", "ということが記載されている",
        "ことが述べられている", "ことが記載されている",
        "であると述べられている", "であると記載されている",
        "と述べられている", "と記載されている", "と伝えられている", "と書かれている",
        "が述べられている", "が記載されている", "が伝えられている", "が書かれている",
        "という内容である", "という内容です", "という内容",
    ]

    /// Line-aware: splits `text` on `"\n"` first, then within each line
    /// splits into sentence-like units, rewrites only the units that open
    /// with a self-referencing subject, and rejoins units within a line
    /// with a single space — but **preserves every line break**, rejoining
    /// lines with `"\n"`.
    ///
    /// This line-awareness was added for the now-removed `refineThreadEntries`
    /// pass (Task #160フォローアップ3〜4), whose whole multi-line
    /// `"■経緯\n<line 1>\n<line 2>\n..."` output this method used to also run
    /// over — an earlier, non-line-aware version of this method would have
    /// collapsed every one of those lines into a single space-joined blob,
    /// destroying the very "fewer, chronological lines" structure that pass
    /// existed to produce. Task #160フォローアップ5 removed that pass
    /// entirely (`TranslationService.summarizeThread`'s doc comment has the
    /// full history), so today's only caller is
    /// `FoundationModelsTranslationService.summarizeThreadEntry`, whose
    /// input has no line breaks at all by the time it reaches here (it
    /// collapses the model's own line breaks to spaces first) — for that
    /// caller a single "line" is the whole input, so this method behaves
    /// exactly as a simple sentence-level stripper would. The line-awareness
    /// itself is kept (not reverted) since it's a strict superset of that
    /// simpler behavior and costs nothing extra for the single-line case.
    ///
    /// Sentence-splitting logic mirrors `OtegamiTranslation.SentenceSplitter`
    /// (deliberately not shared code — that type's own doc comment already
    /// establishes this "a few independent ~15-line call sites, not a
    /// shared abstraction" pattern in this codebase, and `OtegamiCore`
    /// doesn't depend on `OtegamiTranslation` to begin with).
    public static func strip(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.map(stripLine).joined(separator: "\n")
    }

    private static func stripLine(_ line: String) -> String {
        let units = splitIntoUnits(line)
        guard !units.isEmpty else { return line }
        return units.map(rewriteUnitIfNeeded).joined(separator: " ")
    }

    /// Returns `unit` unchanged unless it opens with one of `openers` — the
    /// single gate that keeps this stripper from touching ordinary
    /// sentences (see this type's own doc comment on why that gate is the
    /// whole anti-over-removal story here).
    private static func rewriteUnitIfNeeded(_ unit: String) -> String {
        guard let opener = openers.first(where: { unit.hasPrefix($0) }) else { return unit }
        var body = String(unit.dropFirst(opener.count))
        if body.hasPrefix("、") {
            body.removeFirst()
        }

        // Peel off trailing punctuation first so a `metaVerbSuffixes` match
        // is checked against the sentence's actual content, then
        // reattached after that suffix (if found) is removed.
        let terminators = CharacterSet(charactersIn: ".!?。．！？")
        var trailingPunctuation = ""
        while let last = body.unicodeScalars.last, terminators.contains(last) {
            trailingPunctuation = String(body.removeLast()) + trailingPunctuation
        }

        if let suffix = metaVerbSuffixes.first(where: { body.hasSuffix($0) }) {
            body.removeLast(suffix.count)
        }

        let trimmedBody = body.trimmingCharacters(in: .whitespaces)
        // A sentence that was *only* the opener + a meta-verb (nothing left
        // once both are stripped) has no real content to preserve — return
        // the original unit untouched rather than an empty/truncated
        // fragment, matching this type's "never make things worse" contract.
        return trimmedBody.isEmpty ? unit : trimmedBody + trailingPunctuation
    }

    private static func splitIntoUnits(_ text: String) -> [String] {
        let terminators = CharacterSet(charactersIn: ".!?。．！？")
        var units: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { units.append(trimmed) }
            current = ""
        }
        for character in text {
            current.append(character)
            if character.unicodeScalars.allSatisfy({ terminators.contains($0) }) {
                flush()
            }
        }
        flush()
        return units
    }
}
