import Foundation

/// Task #160フォローアップ4 (最優先実機フィードバック「■現状に全然関係
/// ない話が出てきた」— ハルシネーション): a lightweight, code-side "does
/// this look grounded in the input" check for
/// `TranslationService.summarizeThread`'s `■現状` step
/// (`summarizeThreadDigest`) — not full entailment/fact-checking (out of
/// reach for a simple string utility), just a substring-overlap heuristic
/// over the content-bearing tokens most likely to signal an invented
/// proper noun or number: **digit runs**, **katakana runs** (length >= 2 —
/// loanwords, foreign-style proper nouns), and **Latin-letter runs**
/// (length >= 2 — English names, product names, abbreviations).
///
/// The *root cause* of this feature's real-device report was almost
/// certainly `FoundationModelsTranslationService.currentStatusInstructions`'s
/// own 【出力例】 still using concrete themed content ("水曜14時に
/// イタリアンの店で開催..."、"田中が予約を担当...") — exactly the same
/// "instruction example leaks into unrelated output" failure family this
/// feature had already hit twice before (`summarizeThreadEntryInstructions`/
/// `refineThreadEntriesInstructions`'s own doc comments), just missed on
/// this one instruction. That's fixed at the source (the example is now
/// fully abstract, no digits/katakana/proper nouns at all). This type is
/// the **second, independent layer** `TranslationService.summarizeThread`
/// adds on top of that fix — even a correctly-worded instruction can't
/// guarantee zero hallucination from a generative model, so a cheap
/// code-side check plus a bounded retry plus a mechanical fallback (see
/// that method's own doc comment) closes the loop without needing to trust
/// the instructions alone.
///
/// **Deliberately narrow, matching this feature's own past lessons about
/// over-broad heuristics**: kanji runs are not checked at all — an
/// ordinary Japanese content word almost never survives a paraphrase
/// verbatim even in a fully-grounded answer (`currentStatusInstructions`
/// asks the model to *summarize*, not quote), so checking kanji would flag
/// correct output constantly ("正常出力を落とさない" — this feature's own
/// spec explicitly warned against exactly that). Numbers/katakana/Latin
/// runs are exactly the categories that *should* survive close to verbatim
/// even after paraphrasing (a real amount, a real loanword, a real name),
/// so a mismatch there is a much stronger hallucination signal — see
/// `ThreadDigestGroundingCheckTests` for the boundary cases this scoping
/// was verified against (both "catches an invented number/proper noun" and
/// "never rejects an ordinary correctly-grounded answer").
public enum ThreadDigestGroundingCheck {
    /// `candidate` is considered grounded in `sourceText` when every
    /// digit/katakana/Latin token found in `candidate` also appears (as a
    /// literal substring) somewhere in `sourceText`. Input with no such
    /// tokens at all (e.g. a purely descriptive sentence with no
    /// numbers/loanwords/names) is trivially considered grounded — this
    /// check has nothing to flag either way, and blocking on the mere
    /// *absence* of content words would reject perfectly ordinary correct
    /// output (a thread that never mentions a number or a loanword is
    /// common, not suspicious).
    public static func isLikelyGrounded(_ candidate: String, in sourceText: String) -> Bool {
        let tokens = contentTokens(in: candidate)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { sourceText.contains($0) }
    }

    /// Extracts maximal runs of ASCII digits, Katakana, or Latin letters
    /// (each run at least 2 characters — a lone digit/letter is too common
    /// as incidental punctuation/formatting to be a meaningful signal on
    /// its own) from `text`, in the order they appear.
    static func contentTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentKind: CharacterKind?

        func flush() {
            if current.count >= 2 { tokens.append(current) }
            current = ""
            currentKind = nil
        }

        for character in text {
            let kind = CharacterKind(of: character)
            if let kind, kind == currentKind {
                current.append(character)
            } else {
                flush()
                if let kind {
                    current = String(character)
                    currentKind = kind
                }
            }
        }
        flush()
        return tokens
    }

    private enum CharacterKind: Equatable {
        case digit
        case katakana
        case latin

        /// `nil` for anything else (kanji, hiragana, punctuation, symbols,
        /// whitespace, "■" labels, ...) — those characters never start or
        /// extend a token, they just end whatever run was in progress.
        init?(of character: Character) {
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return nil }
            if character.isASCII, character.isNumber {
                self = .digit
            } else if (0x30A0...0x30FF).contains(scalar.value) {
                // The full Katakana Unicode block — includes the long-vowel
                // mark "ー" (U+30FC) and the katakana middle dot "・"
                // (U+30FB), both of which commonly appear *inside* a real
                // katakana word (e.g. "イタリアン・レストラン") without
                // changing whether the whole run matches as a substring.
                self = .katakana
            } else if character.isASCII, character.isLetter {
                self = .latin
            } else {
                return nil
            }
        }
    }
}
