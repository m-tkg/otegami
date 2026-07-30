import Foundation
import Testing
@testable import OtegamiCore

/// Task #193: `EnvelopeDateSentinel`'s two-condition check in isolation —
/// see that type's doc comment for the full mailcore2 root-cause picture.
@Suite("EnvelopeDateSentinel")
struct EnvelopeDateSentinelTests {
    private let referenceTime = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("flags a date stamped at fetch time while internalDate is genuinely old (the mailcore2 sentinel bug)")
    func flagsSentinelDate() {
        let tenYearsAgo = referenceTime.addingTimeInterval(-10 * 365 * 24 * 60 * 60)
        #expect(EnvelopeDateSentinel.isSuspicious(
            date: referenceTime,
            internalDate: tenYearsAgo,
            referenceTime: referenceTime
        ))
        #expect(EnvelopeDateSentinel.reconciledDate(
            date: referenceTime,
            internalDate: tenYearsAgo,
            referenceTime: referenceTime
        ) == nil)
    }

    @Test("does not flag a genuinely fresh message: date and internalDate both close to referenceTime")
    func doesNotFlagGenuinelyFreshMessage() {
        let justNow = referenceTime.addingTimeInterval(-5)
        let arrivedMomentsAgo = referenceTime.addingTimeInterval(-2)
        #expect(!EnvelopeDateSentinel.isSuspicious(
            date: justNow,
            internalDate: arrivedMomentsAgo,
            referenceTime: referenceTime
        ))
        #expect(EnvelopeDateSentinel.reconciledDate(
            date: justNow,
            internalDate: arrivedMomentsAgo,
            referenceTime: referenceTime
        ) == justNow)
    }

    @Test("does not flag a legitimately old message synced long after the fact: date is far from referenceTime")
    func doesNotFlagOldMessageFarFromReferenceTime() {
        let longAgo = referenceTime.addingTimeInterval(-30 * 24 * 60 * 60)
        #expect(!EnvelopeDateSentinel.isSuspicious(
            date: longAgo,
            internalDate: longAgo,
            referenceTime: referenceTime
        ))
        #expect(EnvelopeDateSentinel.reconciledDate(
            date: longAgo,
            internalDate: longAgo,
            referenceTime: referenceTime
        ) == longAgo)
    }

    @Test("does not flag a legitimate delayed-delivery gap: date and internalDate differ, but date is not close to referenceTime")
    func doesNotFlagLegitimateDeliveryDelay() {
        // A message genuinely sent/received `referenceTime`-adjacent, but
        // whose `Date:` header (the sender's clock, hours before actual
        // delivery — a real, if unusual, case) predates internalDate by
        // more than tolerance. Not close to `referenceTime` itself, so the
        // first condition alone rules this out.
        let sentEarlier = referenceTime.addingTimeInterval(-30 * 24 * 60 * 60 - 3 * 60 * 60)
        let deliveredLater = referenceTime.addingTimeInterval(-30 * 24 * 60 * 60)
        #expect(!EnvelopeDateSentinel.isSuspicious(
            date: sentEarlier,
            internalDate: deliveredLater,
            referenceTime: referenceTime
        ))
    }

    @Test("boundary: exactly at tolerance on both conditions")
    func boundaryToleranceIsInclusiveForCloseness() {
        let tolerance: TimeInterval = 60
        let dateAtExactBoundary = referenceTime.addingTimeInterval(-tolerance)
        let internalDateJustOverBoundary = referenceTime.addingTimeInterval(-tolerance - 120 - 1)
        #expect(EnvelopeDateSentinel.isSuspicious(
            date: dateAtExactBoundary,
            internalDate: internalDateJustOverBoundary,
            referenceTime: referenceTime,
            tolerance: tolerance
        ))
    }

    @Test("boundary: just outside the closeness-to-referenceTime tolerance is not flagged")
    func justOutsideToleranceIsNotFlagged() {
        let tolerance: TimeInterval = 60
        let dateJustOutside = referenceTime.addingTimeInterval(-tolerance - 1)
        let veryOldInternalDate = referenceTime.addingTimeInterval(-10 * 365 * 24 * 60 * 60)
        #expect(!EnvelopeDateSentinel.isSuspicious(
            date: dateJustOutside,
            internalDate: veryOldInternalDate,
            referenceTime: referenceTime,
            tolerance: tolerance
        ))
    }

    @Test("date exactly equal to internalDate is never flagged regardless of referenceTime")
    func dateEqualToInternalDateNeverFlagged() {
        #expect(!EnvelopeDateSentinel.isSuspicious(
            date: referenceTime,
            internalDate: referenceTime,
            referenceTime: referenceTime
        ))
    }
}
