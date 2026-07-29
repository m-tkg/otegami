import Foundation
import Testing
@testable import OtegamiCore

/// Task #123: fixtures below mirror the nested reply-chain shape from a
/// real-device repro captured during development (a Japanese Gmail-style
/// thread quoted four levels deep, attribution lines interleaved with
/// bodies at every nesting level) — same structure, fictional names/
/// addresses (`example.com`) per this repo's no-real-PII rule.
@Suite("QuoteHistoryParser")
struct QuoteHistoryParserTests {
    /// A four-message-deep Japanese Gmail-style reply chain, already in the
    /// "quotedText" shape `QuoteStripper.separatingQuotedText` would hand
    /// this parser (starts right at the first `>` line, top-posted so the
    /// most recently quoted message comes first).
    private let nestedJapaneseQuotedText = """
    > 2026年7月28日(火) 10:15 Sato Hanako <sato.hanako@example.com>:
    > > 山田さん
    > >
    > > 明日の打ち合わせですが、資料を先にお送りしておきますね。
    > > 会議室ではなくオンラインに変更しても大丈夫でしょうか。
    > >
    > > > 2026年7月25日(土) 09:03 Yamada Taro <yamada.taro@example.com>:
    > > > > 佐藤さん
    > > > >
    > > > > 承知しました、来週の打ち合わせの件、日程調整ありがとうございます。
    > > > > 会議室の予約は私の方で進めておきます。
    > > > > 資料は当日までに共有いただければ大丈夫です。
    > > > >
    > > > > > 2026年7月20日(月) 16:47 Sato Hanako <sato.hanako@example.com>:
    > > > > > > 山田さん
    > > > > > >
    > > > > > > お世話になっております。
    > > > > > > 次回の定例ミーティングの日程について、来週のどこかでお時間いただけますでしょうか。
    > > > > > >
    > > > > > > > 2026年7月10日(金) 11:30 Yamada Taro <yamada.taro@example.com>:
    > > > > > > > > 佐藤さん
    > > > > > > > >
    > > > > > > > > 先日はプロジェクトの進捗共有をありがとうございました。
    > > > > > > > > 次回の進行フォーマットについても、追ってこちらから叩き台を送ります。
    """

    @Test("segments a nested Japanese reply chain into 4 messages, newest quoted first")
    func parsesNestedJapaneseHistory() {
        guard case .segments(let segments) = QuoteHistoryParser.parse(nestedJapaneseQuotedText) else {
            Issue.record("expected .segments, got .unparsed")
            return
        }
        #expect(segments.count == 4)

        #expect(segments[0].senderName == "Sato Hanako")
        #expect(segments[0].timestamp == "2026年7月28日(火) 10:15")
        #expect(segments[0].body.contains("明日の打ち合わせですが"))
        #expect(!segments[0].body.contains(">"))

        #expect(segments[1].senderName == "Yamada Taro")
        #expect(segments[1].timestamp == "2026年7月25日(土) 09:03")
        #expect(segments[1].body.contains("承知しました"))

        #expect(segments[2].senderName == "Sato Hanako")
        #expect(segments[2].timestamp == "2026年7月20日(月) 16:47")
        #expect(segments[2].body.contains("お世話になっております"))

        #expect(segments[3].senderName == "Yamada Taro")
        #expect(segments[3].timestamp == "2026年7月10日(金) 11:30")
        #expect(segments[3].body.contains("先日はプロジェクトの進捗共有"))
        // Oldest message, nothing further nested below it.
        #expect(!segments[3].body.contains("さんは"))
    }

    @Test("recovers chronological order from strictly increasing nesting depth")
    func ordersSegmentsByNestingDepth() {
        guard case .segments(let segments) = QuoteHistoryParser.parse(nestedJapaneseQuotedText) else {
            Issue.record("expected .segments")
            return
        }
        let depths = segments.map(\.depth)
        #expect(depths == depths.sorted())
        #expect(Set(depths).count == depths.count, "each level's attribution should land at its own depth")
    }

    @Test("integrates with QuoteStripper.separatingQuotedText end to end")
    func integratesWithQuoteStripperSplit() {
        let newText = "佐藤さん\n\n本日はお忙しい中、打ち合わせのお時間をいただきありがとうございました。資料もわかりやすく、次のステップがイメージできました。"
        let fullBody = "\(newText)\n\n\(nestedJapaneseQuotedText)"

        let split = QuoteStripper.separatingQuotedText(fromPlainText: fullBody)
        #expect(split.newText.trimmingCharacters(in: .whitespacesAndNewlines) == newText)

        guard case .segments(let segments) = QuoteHistoryParser.parse(split.quotedText) else {
            Issue.record("expected .segments from the stripper's quotedText output")
            return
        }
        #expect(segments.count == 4)
        #expect(segments.first?.senderName == "Sato Hanako")
    }

    @Test("falls back to .unparsed for a plain '>' block with no recognizable attribution")
    func fallsBackToUnparsedWithNoAttribution() {
        let text = "> ただの引用行です。\n> 特に差出人や日時の情報はありません。\n> 続きの行。"
        guard case .unparsed(let raw) = QuoteHistoryParser.parse(text) else {
            Issue.record("expected .unparsed")
            return
        }
        // Fallback must hand back the original text untouched — no
        // reformatting/guessing when confidence is low.
        #expect(raw == text)
    }

    @Test("falls back to .unparsed for an empty quotedText")
    func fallsBackToUnparsedForEmptyInput() {
        guard case .unparsed(let raw) = QuoteHistoryParser.parse("") else {
            Issue.record("expected .unparsed")
            return
        }
        #expect(raw.isEmpty)
    }

    @Test("parses a single English 'On ... wrote:' segment")
    func parsesSingleEnglishOnWroteSegment() {
        let text = """
        > On Mon, Jul 27, 2026 at 10:00 AM, John Doe <john@example.com> wrote:
        > Thanks for the update, this all looks good to me.
        > Let's confirm the schedule next week.
        """
        guard case .segments(let segments) = QuoteHistoryParser.parse(text) else {
            Issue.record("expected .segments")
            return
        }
        #expect(segments.count == 1)
        #expect(segments[0].senderName == "John Doe")
        #expect(segments[0].timestamp == "Mon, Jul 27, 2026 at 10:00 AM")
        #expect(segments[0].body.contains("Thanks for the update"))
        #expect(segments[0].body.contains("Let's confirm the schedule"))
    }

    @Test("parses a multi-line Outlook-style From/Sent/To/Subject attribution block")
    func parsesOutlookHeaderBlock() {
        let text = """
        > 差出人: 山田太郎 <yamada@example.com>
        > 送信日時: 2026年7月27日 10:00
        > 宛先: 田中花子 <tanaka@example.com>
        > 件名: Re: 打ち合わせについて
        >
        > 過去のメッセージ本文です。
        """
        guard case .segments(let segments) = QuoteHistoryParser.parse(text) else {
            Issue.record("expected .segments")
            return
        }
        #expect(segments.count == 1)
        #expect(segments[0].senderName == "山田太郎")
        #expect(segments[0].timestamp == "2026年7月27日 10:00")
        #expect(segments[0].body.contains("過去のメッセージ本文です。"))
        // The Sent/To/Subject lines must not leak into the body or spawn
        // their own (bodyless) segments.
        #expect(!segments[0].body.contains("宛先"))
        #expect(!segments[0].body.contains("件名"))
    }

    @Test("a bare 'From:' line with no Sent/Date follow-up still segments (single-line shape)")
    func parsesBareFromLineWithoutBlock() {
        let text = """
        > From: Jane Smith <jane@example.com>
        > Sounds good, see you then.
        """
        guard case .segments(let segments) = QuoteHistoryParser.parse(text) else {
            Issue.record("expected .segments")
            return
        }
        #expect(segments.count == 1)
        #expect(segments[0].senderName == "Jane Smith")
        #expect(segments[0].timestamp == nil)
        #expect(segments[0].body.contains("Sounds good"))
    }
}
