import Foundation
import Testing
@testable import OtegamiCore

/// Task #160フォローアップ2 (実機フィードバック「『この返信では〜が述べられ
/// ている』のような説明調(メタ言及)の口調が気になる」): covers
/// `ThreadEntryMetaCommentaryStripper.strip(_:)` — both that it actually
/// rewrites the reported bad pattern, and (just as important, per the
/// task's own "正規表現ベースで過剰除去しないこと" instruction) that it
/// leaves ordinary sentences without the message-self-referencing opener
/// completely untouched, even when they contain one of the banned verbs as
/// genuine content rather than meta-commentary.
@Suite("ThreadEntryMetaCommentaryStripper")
struct ThreadEntryMetaCommentaryStripperTests {
    @Test("rewrites the exact reported bad pattern into the reported good shape")
    func rewritesReportedBadPattern() {
        let input = "この返信では予算が1人あたり5000円程度であることが述べられている。"
        let result = ThreadEntryMetaCommentaryStripper.strip(input)
        #expect(result == "予算が1人あたり5000円程度。")
        #expect(!result.contains("この返信"))
        #expect(!result.contains("述べられている"))
    }

    @Test("strips the opener even when no known meta-verb suffix follows")
    func stripsOpenerAloneWithoutMatchingSuffix() {
        let input = "この返信では来週の日程を確認したい。"
        let result = ThreadEntryMetaCommentaryStripper.strip(input)
        #expect(result == "来週の日程を確認したい。")
    }

    @Test("recognizes every documented opener/suffix variant")
    func recognizesEveryOpenerAndSuffixVariant() {
        let cases: [(String, String)] = [
            ("このメールでは金曜19時に予約すると記載されている。", "金曜19時に予約する。"),
            ("このメッセージでは会場はイタリアンだと伝えられている。", "会場はイタリアンだ。"),
            ("この返信は来週水曜が候補だという内容です。", "来週水曜が候補だ。"),
            ("このメールは会議室の予約が必要という内容。", "会議室の予約が必要。"),
        ]
        for (input, expected) in cases {
            #expect(ThreadEntryMetaCommentaryStripper.strip(input) == expected)
        }
    }

    @Test("leaves a sentence without the self-referencing opener completely untouched, even if it contains a banned verb as genuine content")
    func leavesGenuineThirdPartyReportedSpeechUntouched() {
        // The real point of this test: "伝えられている"/"述べられている" etc.
        // aren't inherently meta-commentary — they're also how Japanese
        // reports what a *third party* said, which is exactly the kind of
        // detail `summarizeThreadEntry`'s "don't drop content" contract must
        // preserve. Without the leading self-referencing opener, this
        // stripper must never touch it.
        let inputs = [
            "先方からは来月まで待ってほしいと伝えられている。",
            "田中さんの資料には来週の日程が記載されている。",
            "会議室の予約が必要だと本人から述べられている。",
        ]
        for input in inputs {
            #expect(ThreadEntryMetaCommentaryStripper.strip(input) == input)
        }
    }

    @Test("only rewrites the wrapped sentence in a multi-sentence input, leaving the others exactly as-is")
    func onlyRewritesTheWrappedSentenceAmongOthers() {
        let input = "予算は5000円程度。この返信では日程についても確認したいと述べられている。会場はイタリアンで決定。"
        let result = ThreadEntryMetaCommentaryStripper.strip(input)
        #expect(result == "予算は5000円程度。 日程についても確認したい。 会場はイタリアンで決定。")
    }

    @Test("empty input returns empty input")
    func emptyInputReturnsEmpty() {
        #expect(ThreadEntryMetaCommentaryStripper.strip("") == "")
    }

    @Test("input with no terminating punctuation at all is still handled")
    func noTerminatorStillHandled() {
        let input = "この返信では来週の日程を確認したい"
        #expect(ThreadEntryMetaCommentaryStripper.strip(input) == "来週の日程を確認したい")
    }

    @Test("a sentence that is only the opener plus a meta-verb, with no real content left, is returned unchanged rather than emptied")
    func openerPlusSuffixWithNoRemainingContentIsReturnedUnchanged() {
        // Synthetic (not natural Japanese) on purpose — isolates the "opener
        // + suffix consume the entire body" guard specifically, rather than
        // relying on a realistic-but-ambiguous sentence to exercise it.
        let input = "この返信ではが述べられている。"
        #expect(ThreadEntryMetaCommentaryStripper.strip(input) == input)
    }
}
