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
        // Task #160フォローアップ6 (実機フィードバック「感想が書いてある
        // のに『決定事項・依頼や質問・数値・固有名詞は存在しない』という
        // まとめ方をされる」): a sentence that's *purely* a category-
        // presence commentary (see `isCategoryCommentarySentence`'s doc
        // comment) is dropped entirely, not just rewritten — unlike the
        // opener-based meta-commentary above, there's no "real content
        // once the wrapper is peeled off" for these; the whole sentence
        // *is* the wrapper.
        let kept = units.map(rewriteUnitIfNeeded).filter { !isCategoryCommentarySentence($0) }
        // If every unit in this line was pure category commentary, there's
        // nothing left to keep — return the original line untouched rather
        // than an empty string, the same "never make things worse" fallback
        // `rewriteUnitIfNeeded` already uses for its own edge case. This
        // should be rare in practice: `summarizeThreadEntryInstructions`'s
        // primary fix (its own doc comment) should stop the model from ever
        // producing an entry that's *only* this kind of sentence.
        guard !kept.isEmpty else { return line }
        return kept.joined(separator: " ")
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

    /// Task #160フォローアップ6: the category nouns
    /// `summarizeThreadEntryInstructions` names as "don't drop if present"
    /// examples — 実機報告 (2026-07-30) showed the model echoing this exact
    /// vocabulary back as a *verdict* on the message ("決定事項・依頼や
    /// 質問・数値・固有名詞は存在しない") instead of summarizing what the
    /// message actually says (a report on an event, feelings about it,
    /// etc.) — see `isCategoryCommentarySentence`'s doc comment.
    private static let categoryCommentaryCategoryWords = ["決定事項", "依頼", "質問", "数値", "固有名詞"]

    /// Filler phrases/particles a category-commentary sentence is built
    /// from besides the category words themselves — longer, more specific
    /// phrases listed first so e.g. `"記載されていない"` matches before the
    /// bare `"ない"` would only partially consume it (same ordering
    /// discipline as `metaVerbSuffixes` above).
    private static let categoryCommentaryFillerPhrases = [
        "具体的な内容",
        "記載されていない", "記載されている",
        "含まれていない", "含まれている",
        "存在しない", "存在する",
        "見当たらない", "特にない",
        "特に", "ない",
    ]

    /// Particles/connectors a category-commentary sentence is built from —
    /// deliberately generic (not specific to this failure mode) since the
    /// safety net here isn't "only remove known connectors", it's "a real
    /// verb/noun the model actually used will never be in this list, so it
    /// always survives and blocks removal" (see this method's own doc
    /// comment).
    private static let categoryCommentaryConnectors = ["、", "・", "や", "と", "も", "は", "が", "の", "を", "に", "で", "：", ":"]

    /// Task #160フォローアップ6 (実機フィードバック「メールで当日の感想に
    /// ついて書いてあるのにこんなまとめ方をされてしまっていて、感想に
    /// ついての要約がない」): detects a sentence that is **purely a verdict
    /// on which categories are/aren't present** — e.g. the two sentences
    /// from the actual report, `"具体的な内容：特に記載されている決定事項・
    /// 依頼や質問・数値・固有名詞は存在しない。"` and `"決定事項・依頼・
    /// 質問・数値・固有名詞は含まれていない。"` — as opposed to a sentence
    /// that actually summarizes what the message says. The *primary* fix is
    /// `summarizeThreadEntryInstructions` itself (its own doc comment has
    /// the full before/after): reframing "summarize the message" as the
    /// goal and demoting "don't drop decisions/numbers/proper nouns *if
    /// present*" to a secondary condition, plus an explicit ban on writing
    /// this exact kind of category-presence verdict. This is the backstop.
    ///
    /// **Deliberately conservative, same anti-over-removal discipline as
    /// the opener-based rewrite above**: a sentence only counts as category
    /// commentary when, after removing an optional leading `"具体的な内容"`
    /// marker, every one of its filler phrases/particles/category words,
    /// **nothing is left over**. A real verb or noun phrase (e.g.
    /// `"確認した"`, `"進めています"`, any actual summarized content) is
    /// never in `categoryCommentaryFillerPhrases`/`categoryCommentaryConnectors`,
    /// so any sentence that mixes category words with real content always
    /// leaves a non-empty residual and is left completely untouched — e.g.
    /// `"依頼と数値の確認を進めています。"` survives intact (see
    /// `ThreadEntryMetaCommentaryStripperTests`'s negative cases). Also
    /// requires **at least two** category-word occurrences before even
    /// attempting the residual check, since a single incidental mention
    /// (`"決定事項は来週まとめます"`) is ordinary content, not the
    /// multi-category checklist shape this failure mode actually produces.
    private static func isCategoryCommentarySentence(_ sentence: String) -> Bool {
        var body = sentence
        let terminators = CharacterSet(charactersIn: ".!?。．！？")
        while let last = body.unicodeScalars.last, terminators.contains(last) {
            body.removeLast()
        }
        body = body.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return false }

        let categoryWordOccurrences = categoryCommentaryCategoryWords.reduce(0) { total, word in
            total + max(0, body.components(separatedBy: word).count - 1)
        }
        guard categoryWordOccurrences >= 2 else { return false }

        var residual = body
        for phrase in categoryCommentaryFillerPhrases {
            residual = residual.replacingOccurrences(of: phrase, with: "")
        }
        for word in categoryCommentaryCategoryWords {
            residual = residual.replacingOccurrences(of: word, with: "")
        }
        for connector in categoryCommentaryConnectors {
            residual = residual.replacingOccurrences(of: connector, with: "")
        }
        return residual.trimmingCharacters(in: .whitespaces).isEmpty
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
