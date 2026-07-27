import Foundation
import Testing
@testable import OtegamiCore

@Suite("Threader")
struct ThreaderTests {
    private func date(_ offsetSeconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offsetSeconds)
    }

    private func facts(
        id: Int64,
        messageId: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        subject: String? = nil,
        participants: Set<String> = [],
        date: Date = Date(timeIntervalSince1970: 1_700_000_000),
        gmailThreadId: Int64? = nil,
        fromAddress: String? = nil
    ) -> Threader.MessageFacts {
        Threader.MessageFacts(
            id: id, messageId: messageId, inReplyTo: inReplyTo, references: references,
            normalizedSubject: subject, participants: participants, date: date, gmailThreadId: gmailThreadId,
            fromAddress: fromAddress
        )
    }

    // MARK: (1) Gmail X-GM-THRID priority

    @Test("a Gmail thread id wins even when References would suggest a different thread")
    func gmailThreadIdTakesPriority() {
        let context = Threader.ExistingThreadContext(
            threadIdByMessageId: ["<a@x>": 99],
            threadIdByGmailThreadId: [555: 1]
        )
        let message = facts(id: 2, references: ["<a@x>"], gmailThreadId: 555)
        #expect(Threader.decide(for: message, context: context) == .join(threadId: 1))
    }

    // MARK: (2) References/In-Reply-To

    @Test("a message referencing an already-threaded message joins that thread")
    func referencesJoinExistingThread() {
        let context = Threader.ExistingThreadContext(threadIdByMessageId: ["<seed-2@otegami.test>": 10])
        let reply = facts(id: 3, inReplyTo: "<seed-2@otegami.test>", references: ["<seed-2@otegami.test>"])
        #expect(Threader.decide(for: reply, context: context) == .join(threadId: 10))
    }

    @Test("In-Reply-To alone (no References header) still joins the referenced thread")
    func inReplyToAloneJoins() {
        let context = Threader.ExistingThreadContext(threadIdByMessageId: ["<orig@x>": 42])
        let reply = facts(id: 3, inReplyTo: "<orig@x>")
        #expect(Threader.decide(for: reply, context: context) == .join(threadId: 42))
    }

    @Test("references pointing at an unknown message-id, with no subject match, starts a new thread")
    func unknownReferenceFallsThroughToNewThread() {
        let context = Threader.ExistingThreadContext()
        let message = facts(id: 1, inReplyTo: "<unknown@x>", references: ["<unknown@x>"], subject: "hello")
        #expect(Threader.decide(for: message, context: context) == .createNew)
    }

    // MARK: (4) Thread merge

    @Test("a message bridging two previously-separate threads merges the smaller into the larger")
    func mergesTwoThreadsPreferringTheLargerAsTarget() {
        let context = Threader.ExistingThreadContext(
            threadIdByMessageId: ["<a@x>": 1, "<b@x>": 2],
            threadMessageCounts: [1: 5, 2: 1]
        )
        // A forwarded message that quotes/references both prior
        // conversations' latest messages.
        let bridge = facts(id: 9, references: ["<a@x>", "<b@x>"])
        #expect(Threader.decide(for: bridge, context: context) == .joinAndMerge(threadId: 1, mergedThreadIds: [2]))
    }

    @Test("a merge with tied message counts breaks the tie toward the lower thread id")
    func mergeTieBreaksTowardLowerThreadId() {
        let context = Threader.ExistingThreadContext(
            threadIdByMessageId: ["<a@x>": 20, "<b@x>": 10],
            threadMessageCounts: [20: 3, 10: 3]
        )
        let bridge = facts(id: 9, references: ["<a@x>", "<b@x>"])
        #expect(Threader.decide(for: bridge, context: context) == .joinAndMerge(threadId: 10, mergedThreadIds: [20]))
    }

    // MARK: (3) Subject fallback

    @Test("no References: same normalized subject + overlapping participants within the window joins by subject")
    func subjectFallbackJoinsWithinWindow() {
        let original = date(0)
        let context = Threader.ExistingThreadContext(
            subjectCandidatesByNormalizedSubject: [
                "来月の懇親会について": [
                    Threader.SubjectCandidate(threadId: 7, participants: ["test1@otegami.test", "aiko@otegami.test"], date: original),
                ],
            ]
        )
        // Japanese "Re:" prefix already stripped by SubjectNormalizer
        // before this facts value is constructed — Threader itself only
        // ever compares already-normalized subjects.
        let reply = facts(
            id: 2,
            subject: "来月の懇親会について",
            participants: ["test1@otegami.test", "aiko@otegami.test"],
            date: date(3600 * 5)
        )
        #expect(Threader.decide(for: reply, context: context) == .join(threadId: 7))
    }

    @Test("subject match outside the 7-day window falls back to a new thread")
    func subjectFallbackRespectsWindow() {
        let original = date(0)
        let context = Threader.ExistingThreadContext(
            subjectCandidatesByNormalizedSubject: [
                "来月の懇親会について": [
                    Threader.SubjectCandidate(threadId: 7, participants: ["test1@otegami.test"], date: original),
                ],
            ]
        )
        let tooLate = facts(
            id: 2,
            subject: "来月の懇親会について",
            participants: ["test1@otegami.test"],
            date: original.addingTimeInterval(8 * 24 * 60 * 60)
        )
        #expect(Threader.decide(for: tooLate, context: context) == .createNew)
    }

    @Test("subject match with no overlapping participants (different conversation, same subject) starts a new thread")
    func subjectFallbackRequiresParticipantOverlap() {
        let context = Threader.ExistingThreadContext(
            subjectCandidatesByNormalizedSubject: [
                "ミーティングのご案内": [
                    Threader.SubjectCandidate(threadId: 7, participants: ["someone-else@otegami.test"], date: date(0)),
                ],
            ]
        )
        let unrelated = facts(id: 2, subject: "ミーティングのご案内", participants: ["test1@otegami.test"], date: date(60))
        #expect(Threader.decide(for: unrelated, context: context) == .createNew)
    }

    @Test("subject fallback picks the most recently active matching thread when several qualify")
    func subjectFallbackPrefersMostRecentCandidate() {
        let context = Threader.ExistingThreadContext(
            subjectCandidatesByNormalizedSubject: [
                "s": [
                    Threader.SubjectCandidate(threadId: 1, participants: ["p@x"], date: date(0)),
                    Threader.SubjectCandidate(threadId: 2, participants: ["p@x"], date: date(3600)),
                ],
            ]
        )
        let message = facts(id: 3, subject: "s", participants: ["p@x"], date: date(4000))
        #expect(Threader.decide(for: message, context: context) == .join(threadId: 2))
    }

    @Test("no subject and no references starts a new thread")
    func noSignalStartsNewThread() {
        let context = Threader.ExistingThreadContext()
        let message = facts(id: 1)
        #expect(Threader.decide(for: message, context: context) == .createNew)
    }

    // MARK: 実機フィードバック第3弾 (D): no-reply senders never use subject fallback

    @Test("a no-reply sender never joins by subject fallback, even with matching subject/participants/window")
    func noReplySenderNeverJoinsBySubjectFallback() {
        let original = date(0)
        let context = Threader.ExistingThreadContext(
            subjectCandidatesByNormalizedSubject: [
                "本日のお知らせ": [
                    Threader.SubjectCandidate(threadId: 7, participants: ["test1@otegami.test", "no-reply@service.example"], date: original),
                ],
            ]
        )
        let notification = facts(
            id: 2,
            subject: "本日のお知らせ",
            participants: ["test1@otegami.test", "no-reply@service.example"],
            date: date(3600),
            fromAddress: "no-reply@service.example"
        )
        #expect(Threader.decide(for: notification, context: context) == .createNew)
    }

    @Test("isNoReplyAddress recognizes common no-reply/noreply/donotreply patterns, case-insensitively")
    func isNoReplyAddressRecognizesCommonPatterns() {
        #expect(Threader.isNoReplyAddress("No-Reply@Service.example"))
        #expect(Threader.isNoReplyAddress("noreply@service.example"))
        #expect(Threader.isNoReplyAddress("donotreply@service.example"))
        #expect(Threader.isNoReplyAddress("do-not-reply@service.example"))
        #expect(!Threader.isNoReplyAddress("aiko@otegami.test"))
        #expect(!Threader.isNoReplyAddress(nil))
    }
}
