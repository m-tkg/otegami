import Foundation
import Testing
@testable import SyncEngine

/// Task #152 (実機報告「フラグ/アーカイブ操作後、他の受信箱一覧への反映が
/// 遅い」): pure unit tests for `TargetedResyncScheduler`'s debounce/coalesce
/// decision logic, driven entirely with synthetic `Date`s — no `Task.sleep`,
/// no actor, no real wall-clock waiting, matching the type's own "kept
/// synchronous specifically so this can be tested fast" doc comment.
@Suite("TargetedResyncScheduler")
struct TargetedResyncSchedulerTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a single request fires only once its debounce window elapses")
    func singleRequestFiresAfterDebounceWindow() {
        var scheduler = TargetedResyncScheduler(debounceInterval: 3)
        scheduler.request(accountId: "a1", mailboxIds: [10], now: epoch)

        // Not yet due mid-window.
        #expect(scheduler.due(now: epoch.addingTimeInterval(2)).isEmpty)
        #expect(scheduler.isPending(accountId: "a1"))

        // Due exactly at (or past) the debounce window.
        let due = scheduler.due(now: epoch.addingTimeInterval(3))
        #expect(due.count == 1)
        #expect(due.first?.accountId == "a1")
        #expect(due.first?.mailboxIds == [10])
        #expect(!scheduler.isPending(accountId: "a1"))
    }

    @Test("a burst of requests on the same account resets the debounce window each time (debounce)")
    func burstResetsDebounceWindow() {
        var scheduler = TargetedResyncScheduler(debounceInterval: 3)
        scheduler.request(accountId: "a1", mailboxIds: [10], now: epoch)
        // A second request arrives before the first would have fired —
        // this should push the fire time out again, not fire early.
        scheduler.request(accountId: "a1", mailboxIds: [10], now: epoch.addingTimeInterval(2))

        // 3s after the *first* request (when it would have originally
        // fired) — still not due, since the second request reset the clock.
        #expect(scheduler.due(now: epoch.addingTimeInterval(3)).isEmpty)

        // 3s after the *second* request.
        let due = scheduler.due(now: epoch.addingTimeInterval(5))
        #expect(due.count == 1)
    }

    @Test("requests for different mailboxes on the same account coalesce into one union (合流)")
    func requestsCoalesceMailboxIds() {
        var scheduler = TargetedResyncScheduler(debounceInterval: 3)
        scheduler.request(accountId: "a1", mailboxIds: [10], now: epoch)
        scheduler.request(accountId: "a1", mailboxIds: [20, 30], now: epoch.addingTimeInterval(1))

        let due = scheduler.due(now: epoch.addingTimeInterval(10))
        #expect(due.count == 1)
        #expect(due.first?.mailboxIds == [10, 20, 30])
    }

    @Test("different accounts are scheduled independently")
    func differentAccountsAreIndependent() {
        var scheduler = TargetedResyncScheduler(debounceInterval: 3)
        scheduler.request(accountId: "a1", mailboxIds: [10], now: epoch)
        scheduler.request(accountId: "a2", mailboxIds: [99], now: epoch.addingTimeInterval(2))

        // a1's window has elapsed, a2's hasn't yet.
        let dueAtT3 = scheduler.due(now: epoch.addingTimeInterval(3))
        #expect(dueAtT3.map(\.accountId) == ["a1"])

        let dueAtT5 = scheduler.due(now: epoch.addingTimeInterval(5))
        #expect(dueAtT5.map(\.accountId) == ["a2"])
    }

    @Test("due(now:) never returns the same account twice")
    func dueDoesNotRepeat() {
        var scheduler = TargetedResyncScheduler(debounceInterval: 1)
        scheduler.request(accountId: "a1", mailboxIds: [10], now: epoch)

        let firstPop = scheduler.due(now: epoch.addingTimeInterval(5))
        #expect(firstPop.count == 1)

        let secondPop = scheduler.due(now: epoch.addingTimeInterval(6))
        #expect(secondPop.isEmpty)
    }

    @Test("a request with an empty mailboxIds set is a no-op")
    func emptyMailboxIdsIsNoOp() {
        var scheduler = TargetedResyncScheduler(debounceInterval: 3)
        scheduler.request(accountId: "a1", mailboxIds: [], now: epoch)
        #expect(!scheduler.isPending(accountId: "a1"))
        #expect(scheduler.nextFireAt == nil)
    }

    @Test("nextFireAt reports the earliest pending fire time across all accounts")
    func nextFireAtIsEarliestAcrossAccounts() {
        var scheduler = TargetedResyncScheduler(debounceInterval: 3)
        scheduler.request(accountId: "a1", mailboxIds: [10], now: epoch.addingTimeInterval(5))
        scheduler.request(accountId: "a2", mailboxIds: [20], now: epoch)

        #expect(scheduler.nextFireAt == epoch.addingTimeInterval(3))
    }

    @Test("nextFireAt is nil once every pending account has fired")
    func nextFireAtIsNilWhenNothingPending() {
        var scheduler = TargetedResyncScheduler(debounceInterval: 1)
        scheduler.request(accountId: "a1", mailboxIds: [10], now: epoch)
        _ = scheduler.due(now: epoch.addingTimeInterval(5))
        #expect(scheduler.nextFireAt == nil)
    }
}
