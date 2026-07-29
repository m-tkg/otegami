import Foundation
import Testing
import OtegamiStore
@testable import SyncEngine

/// Regression coverage for Task #147 (実機報告「本文の後着で要約/翻訳ボタンが
/// 有効化されない」) — see `MessageBodyObservationGate`'s own doc comment for
/// the root cause (`MessageView.load()`のワンショット取得は、後からDBへ届いた
/// 本文を二度と観測しない) and what this gate decides.
@Suite("MessageBodyObservationGate")
struct MessageBodyObservationGateTests {
    private let messageId: Int64 = 42

    @Test("a still-empty observation (no row yet) never applies")
    func noRowNeverApplies() {
        #expect(MessageBodyObservationGate.shouldApply(current: nil, incoming: nil) == false)
    }

    @Test("the first real body arriving (current nil → incoming non-nil) applies — the #147 fix's core case")
    func firstArrivalApplies() {
        let incoming = MessageBodyRecord(messageId: messageId, plainText: "Hello", fetchedAt: Date())
        #expect(MessageBodyObservationGate.shouldApply(current: nil, incoming: incoming) == true)
    }

    @Test("a redundant re-delivery of the exact same row does not re-apply")
    func identicalRedeliveryDoesNotReapply() {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let current = MessageBodyRecord(messageId: messageId, plainText: "Hello", html: nil, fetchedAt: fetchedAt)
        let incoming = MessageBodyRecord(messageId: messageId, plainText: "Hello", html: nil, fetchedAt: fetchedAt)
        #expect(MessageBodyObservationGate.shouldApply(current: current, incoming: incoming) == false)
    }

    @Test("a genuinely different body (e.g. a later, fuller fetch) applies")
    func genuinelyChangedBodyApplies() {
        let current = MessageBodyRecord(messageId: messageId, plainText: "Hello", fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let incoming = MessageBodyRecord(messageId: messageId, plainText: "Hello, world!", fetchedAt: Date(timeIntervalSince1970: 1_700_000_100))
        #expect(MessageBodyObservationGate.shouldApply(current: current, incoming: incoming) == true)
    }

    @Test("a row disappearing (incoming nil, e.g. the message was deleted) never applies — load()'s own error/loading state stays as-is")
    func rowDisappearingNeverApplies() {
        let current = MessageBodyRecord(messageId: messageId, plainText: "Hello", fetchedAt: Date())
        #expect(MessageBodyObservationGate.shouldApply(current: current, incoming: nil) == false)
    }
}
