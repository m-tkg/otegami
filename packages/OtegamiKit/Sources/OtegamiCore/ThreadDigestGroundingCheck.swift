import Foundation

/// **現在このユーティリティを呼んでいる箇所は無い (Task #160フォローアップ5、
/// ユーザー指示「スレッド要約の最終形への簡素化」で撤去済み) — 意図的に
/// 残してある。** 経緯: Task #160フォローアップ4 (最優先実機フィードバック
/// 「■現状に全然関係ない話が出てきた」— ハルシネーション) で、
/// `TranslationService.summarizeThread`の`■現状`生成段
/// (`summarizeThreadDigest`、廃止済み) の出力を検証するために書かれた
/// 軽量ヒューリスティックだった。その後のフォローアップ5で「per-message
/// 抽出結果をそのまま時系列に並べるだけ」という最終形に簡素化され、
/// `■現状`生成段そのものが撤去された結果、このユーティリティを呼ぶ
/// 唯一の呼び出し元が消えた。
///
/// それでも削除せず残しているのは: (1) 実装・テストとも既に検証済みで
/// 保守コストがほぼゼロ (このファイル単体で完結、他の型に依存しない)、
/// (2) 「モデルにもう一段何かを書かせる」設計が将来また必要になった場合
/// (例えば添付ファイルの自動タグ付けや、別の要約系機能) に、同じ
/// 「生成結果が入力に接地しているか」を検証するニーズが再発する可能性が
/// 現実的にある、(3) 実際に「例文の題材が出力に漏れる」バグを2回
/// (Task #160フォローアップ2/4) 踏んだ経験から得た設計 (数値・カタカナ語・
/// ラテン文字語という3カテゴリへの意図的な限定、漢字語を対象外にする
/// 理由) 自体に再利用価値があるため。呼び出し元が現れたら、このdoc
/// comment の冒頭2段落を新しい利用箇所の説明に置き換えること。
///
/// 以下は元の (Task #160フォローアップ4時点の) 設計意図の記録:
///
/// a lightweight, code-side "does this look grounded in the input" check —
/// not full entailment/fact-checking (out of reach for a simple string
/// utility), just a substring-overlap heuristic over the content-bearing
/// tokens most likely to signal an invented proper noun or number: **digit
/// runs**, **katakana runs** (length >= 2 — loanwords, foreign-style proper
/// nouns), and **Latin-letter runs** (length >= 2 — English names, product
/// names, abbreviations).
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
