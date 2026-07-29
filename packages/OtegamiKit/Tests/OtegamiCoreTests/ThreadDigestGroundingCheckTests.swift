import Foundation
import Testing
@testable import OtegamiCore

/// Task #160フォローアップ4 (最優先実機フィードバック「■現状に全然関係
/// ない話が出てきた」— ハルシネーション): covers
/// `ThreadDigestGroundingCheck` — both that it actually catches an invented
/// number/proper noun not present anywhere in the source, and (just as
/// important, per this feature's own "過剰に厳しくして正常出力を落とさない
/// ように" instruction) that it never rejects an ordinary, correctly-
/// grounded answer, even when phrased quite differently from the source
/// text (paraphrasing is expected and must not be penalized).
@Suite("ThreadDigestGroundingCheck")
struct ThreadDigestGroundingCheckTests {
    @Test("a candidate whose numbers/katakana all appear in the source is grounded")
    func groundedCandidatePasses() {
        let source = """
        [07/20] 田中太郎: 予算は1人あたり5000円程度を考えています。イタリアンのお店だとその予算内で収まりそうです。
        [07/20] 佐藤花子: 金曜19時にイタリアンのお店を予約することに決定した。
        """
        let candidate = "来週金曜19時にイタリアンでの打ち合わせを行うことが合意され、予算は1人あたり5000円程度と想定されている。"
        #expect(ThreadDigestGroundingCheck.isLikelyGrounded(candidate, in: source))
    }

    @Test("a candidate mentioning a number absent from the source is flagged as not grounded")
    func inventedNumberFailsGrounding() {
        let source = "[07/20] 田中太郎: 予算は1人あたり5000円程度を考えています。"
        let candidate = "予算は1人あたり10000円で合意された。"
        #expect(!ThreadDigestGroundingCheck.isLikelyGrounded(candidate, in: source))
    }

    @Test("a candidate mentioning a katakana word absent from the source is flagged as not grounded")
    func inventedKatakanaWordFailsGrounding() {
        let source = "[07/20] 田中太郎: 来週の会場を検討しています。"
        // A completely unrelated topic leaking in — the exact shape of the
        // real-device report ("■現状に全然関係ない話が出てきた").
        let candidate = "ミーティングの議事録を確認する必要がある。"
        #expect(!ThreadDigestGroundingCheck.isLikelyGrounded(candidate, in: source))
    }

    @Test("a candidate with no numbers/katakana/Latin tokens at all is trivially grounded — nothing to check either way")
    func noContentTokensIsTriviallyGrounded() {
        let source = "[07/20] 田中太郎: 会場の候補について検討中です。"
        let candidate = "会場についてまだ結論が出ていない状態である。"
        #expect(ThreadDigestGroundingCheck.isLikelyGrounded(candidate, in: source))
        // Even against a totally unrelated source — this check has no
        // content-word signal to work with either way, by design (see this
        // type's own doc comment on why blocking on absence would reject
        // ordinary correct output).
        #expect(ThreadDigestGroundingCheck.isLikelyGrounded(candidate, in: "全く関係のない別の話題です。"))
    }

    @Test("a fully abstract placeholder-shaped candidate (this feature's own fixed instruction example) is always grounded, by construction")
    func abstractPlaceholderExampleIsAlwaysGrounded() {
        // Mirrors `currentStatusInstructions`'s post-fix 【出力例】 — chosen
        // specifically so that even if it leaked verbatim, it couldn't
        // introduce a wrong concrete fact. Confirms it has no content
        // tokens that could ever mismatch.
        let example = "いずれかの案で進めることが合意され、詳細はまだ決まっていない。担当者が確認を行い、結果が出次第共有する予定。"
        #expect(ThreadDigestGroundingCheck.contentTokens(in: example).isEmpty)
    }

    @Test("contentTokens extracts multi-character digit/katakana/Latin runs, ignores lone characters and kanji/hiragana")
    func contentTokensExtraction() {
        let text = "5000円のA社案件、イタリアン・レストランで木曜14時に確認します。B。"
        let tokens = ThreadDigestGroundingCheck.contentTokens(in: text)
        #expect(tokens.contains("5000"))
        #expect(tokens.contains("14"))
        #expect(tokens.contains("イタリアン・レストラン"))
        // Lone Latin letters ("A", "B") are below the length-2 threshold —
        // too common as incidental single-character labels to be a
        // meaningful signal on their own.
        #expect(!tokens.contains("A"))
        #expect(!tokens.contains("B"))
        // Kanji/hiragana never contribute tokens at all.
        #expect(!tokens.contains(where: { $0.contains("円") || $0.contains("社") || $0.contains("案件") }))
    }

    @Test("a katakana run containing the long-vowel mark or middle dot is treated as one token, matching a source that spells it identically")
    func katakanaRunWithInternalPunctuationMatchesWhole() {
        let source = "[07/20] 田中太郎: イタリアン・レストランを予約しました。"
        let candidate = "イタリアン・レストランの予約が完了した。"
        #expect(ThreadDigestGroundingCheck.isLikelyGrounded(candidate, in: source))
    }

    @Test("empty candidate is trivially grounded")
    func emptyCandidateIsGrounded() {
        #expect(ThreadDigestGroundingCheck.isLikelyGrounded("", in: "何らかのソーステキスト。"))
    }
}
