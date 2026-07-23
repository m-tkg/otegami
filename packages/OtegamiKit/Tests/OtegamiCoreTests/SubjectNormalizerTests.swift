import Testing
@testable import OtegamiCore

@Suite("SubjectNormalizer")
struct SubjectNormalizerTests {
    @Test("plain subject is unchanged")
    func plainSubject() {
        #expect(SubjectNormalizer.normalize("Team lunch on Friday") == "Team lunch on Friday")
    }

    @Test("single Re: prefix is stripped")
    func singleReplyPrefix() {
        #expect(SubjectNormalizer.normalize("Re: Team lunch") == "Team lunch")
    }

    @Test("repeated Re: prefixes are all stripped")
    func repeatedReplyPrefixes() {
        #expect(SubjectNormalizer.normalize("Re: Re: こんにちは") == "こんにちは")
    }

    @Test("uppercase RE: prefix is stripped")
    func uppercaseReplyPrefix() {
        #expect(SubjectNormalizer.normalize("RE: quarterly report") == "quarterly report")
    }

    @Test("full-width Ｆｗｄ： prefix is stripped")
    func fullWidthForwardPrefix() {
        #expect(SubjectNormalizer.normalize("Ｆｗｄ：件名") == "件名")
    }

    @Test("full-width Ｒｅ： prefix is stripped")
    func fullWidthReplyPrefix() {
        #expect(SubjectNormalizer.normalize("Ｒｅ：見積もりの件") == "見積もりの件")
    }

    @Test("Japanese 返信: prefix is stripped")
    func japaneseReplyPrefix() {
        #expect(SubjectNormalizer.normalize("返信: 明日の予定について") == "明日の予定について")
    }

    @Test("Japanese 転送: prefix is stripped")
    func japaneseForwardPrefix() {
        #expect(SubjectNormalizer.normalize("転送: 会議資料") == "会議資料")
    }

    @Test("mixed Re:/Fwd: chain is fully stripped")
    func mixedReplyForwardChain() {
        #expect(SubjectNormalizer.normalize("Fwd: Re: Fwd: budget review") == "budget review")
    }

    @Test("counter form Re[2]: is stripped")
    func counterFormPrefix() {
        #expect(SubjectNormalizer.normalize("Re[2]: status update") == "status update")
    }
}
