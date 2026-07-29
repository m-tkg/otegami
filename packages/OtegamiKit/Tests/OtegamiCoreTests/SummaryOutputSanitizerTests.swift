import Foundation
import Testing
@testable import OtegamiCore

/// Task #122: covers the two real-device failure modes a screenshot report
/// showed — (a) the 3-part ■要約/■伝えたいこと/■アクション structure
/// repeating itself, and (b) the correct structure followed by
/// `FoundationModelsTranslationService.summarizeInstructions`'s own
/// label-definition wording leaking into the output verbatim. Both samples
/// below are shaped like the actual repro (correct answer first, garbage
/// after), not hypothetical edge cases.
@Suite("SummaryOutputSanitizer")
struct SummaryOutputSanitizerTests {
    @Test("passes a single well-formed 3-part block through unchanged")
    func wellFormedBlockPassesThrough() {
        let text = """
        ■要約
        見積もりの件について、来週の打ち合わせ日程を確認する返信です。

        ■伝えたいこと
        丁寧に日程調整を依頼している。

        ■アクション
        来週水曜までに希望日を返信する。
        """
        #expect(SummaryOutputSanitizer.sanitize(text) == text)
    }

    @Test("(a) drops a second, repeated 3-part block")
    func dropsRepeatedBlock() {
        let text = """
        ■要約
        見積もりの件について、来週の打ち合わせ日程を確認する返信です。

        ■伝えたいこと
        丁寧に日程調整を依頼している。

        ■アクション
        来週水曜までに希望日を返信する。

        ■要約
        見積もりの件について、来週の打ち合わせ日程を確認する返信です。もう一度。

        ■伝えたいこと
        丁寧に日程調整を依頼している。もう一度。

        ■アクション
        来週水曜までに希望日を返信する。もう一度。
        """
        let sanitized = SummaryOutputSanitizer.sanitize(text)
        #expect(sanitized == """
        ■要約
        見積もりの件について、来週の打ち合わせ日程を確認する返信です。

        ■伝えたいこと
        丁寧に日程調整を依頼している。

        ■アクション
        来週水曜までに希望日を返信する。
        """)
        // Exactly one of each label survives, and none of the repeated
        // block's "もう一度" content leaks through.
        #expect(sanitized.components(separatedBy: SummaryOutputSanitizer.summaryLabel).count == 2)
        #expect(!sanitized.contains("もう一度"))
    }

    @Test("(b) drops leaked instruction-definition text after the real answer")
    func dropsLeakedInstructionText() {
        // Shaped after the actual repro: the correct 3-part block, followed
        // by `summarizeInstructions`'s own "■Label — description" wording
        // (English, concatenated with the label on one line) with the
        // labels' answers restated afterward.
        let text = """
        ■要約
        見積もりの件について、来週の打ち合わせ日程を確認する返信です。

        ■伝えたいこと
        丁寧に日程調整を依頼している。

        ■アクション
        来週水曜までに希望日を返信する。

        ■要約 — in about 2 short sentences, describe what this email's own new reply says. This is the main part and its primary subject must always be the new reply, never the quoted history.
        見積もりの件について、来週の打ち合わせ日程を確認する返信です。
        ■伝えたいこと — in about one sentence, describe the sender's intent and tone in writing the new reply.
        丁寧に日程調整を依頼している。
        ■アクション — state in about one sentence what action, if any, the new reply asks the recipient to take.
        来週水曜までに希望日を返信する。
        """
        let sanitized = SummaryOutputSanitizer.sanitize(text)
        #expect(sanitized == """
        ■要約
        見積もりの件について、来週の打ち合わせ日程を確認する返信です。

        ■伝えたいこと
        丁寧に日程調整を依頼している。

        ■アクション
        来週水曜までに希望日を返信する。
        """)
        #expect(!sanitized.contains("in about"))
        #expect(!sanitized.contains("describe"))
    }

    @Test("(a)+(b) combined: repeated block AND leaked instructions after it")
    func dropsEverythingAfterFirstCompleteBlock() {
        let text = """
        ■要約
        新規本文の要約です。

        ■伝えたいこと
        お礼を伝えたい。

        ■アクション
        特になし

        ■要約
        別バージョンの要約。

        ■要約 — description leaked here.
        繰り返し。
        """
        let sanitized = SummaryOutputSanitizer.sanitize(text)
        #expect(sanitized == """
        ■要約
        新規本文の要約です。

        ■伝えたいこと
        お礼を伝えたい。

        ■アクション
        特になし
        """)
    }

    @Test("handles the label and its content sharing the same line")
    func handlesLabelAndContentOnSameLine() {
        let text = """
        ■要約: 新規本文の要約です。
        ■伝えたいこと: お礼を伝えたい。
        ■アクション: 特になし
        """
        let sanitized = SummaryOutputSanitizer.sanitize(text)
        #expect(sanitized == """
        ■要約
        新規本文の要約です。

        ■伝えたいこと
        お礼を伝えたい。

        ■アクション
        特になし
        """)
    }

    @Test("falls back to the trimmed original text when the labels can't all be found")
    func fallsBackWhenLabelsMissing() {
        let text = "  普通の要約文だけが返ってきた。ラベルは無い。  "
        #expect(SummaryOutputSanitizer.sanitize(text) == "普通の要約文だけが返ってきた。ラベルは無い。")
    }

    @Test("falls back when only some labels are present")
    func fallsBackWhenPartialLabelsPresent() {
        let text = """
        ■要約
        本文だけあって、他のラベルが無い。
        """
        #expect(SummaryOutputSanitizer.sanitize(text) == text)
    }

    @Test("multi-line content within a part is preserved")
    func preservesMultiLineContent() {
        let text = """
        ■要約
        1行目。
        2行目。

        ■伝えたいこと
        お礼を伝えたい。

        ■アクション
        特になし
        """
        let sanitized = SummaryOutputSanitizer.sanitize(text)
        #expect(sanitized.contains("1行目。\n2行目。"))
    }
}
