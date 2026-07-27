import Foundation
import OtegamiRelayAPI
import Testing

@testable import PushRelayClient

@Suite("WatchReconciler.plan")
struct WatchReconcilerTests {
    private func summary(watchId: String, accountId: String) -> WatchSummary {
        WatchSummary(watchId: watchId, accountId: accountId, imapHost: "imap.example.com", mailbox: "INBOX", createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test("everything already agrees — no-op")
    func noOpWhenEverythingAgrees() {
        let plan = WatchReconciler.plan(
            localPasswordAccountIds: ["a1"],
            localWatchMap: ["a1": "w1"],
            serverWatches: [summary(watchId: "w1", accountId: "a1")]
        )
        #expect(plan.isEmpty)
    }

    @Test("a relay watch for a deleted account is queued for deletion, and its stale local map entry is forgotten")
    func deletesOrphanedWatch() {
        // The actual M9 bug: account "a1" was deleted locally (and its
        // `DELETE /v1/watches/:id` either never ran or failed silently),
        // but the relay still has a live watch — and the local map (not
        // yet cleared, mirroring `unregisterWatch`'s failure path) still
        // remembers it too.
        let plan = WatchReconciler.plan(
            localPasswordAccountIds: [],
            localWatchMap: ["a1": "w1"],
            serverWatches: [summary(watchId: "w1", accountId: "a1")]
        )
        #expect(plan.watchIdsToDelete == ["w1"])
        #expect(plan.accountIdsToRegister.isEmpty)
        #expect(plan.watchIdsToAdoptLocally.isEmpty)
        #expect(plan.accountIdsToForgetLocally == ["a1"])
    }

    @Test("a local account with no relay watch is queued for registration")
    func registersMissingWatch() {
        let plan = WatchReconciler.plan(
            localPasswordAccountIds: ["a1", "a2"],
            localWatchMap: ["a1": "w1"],
            serverWatches: [summary(watchId: "w1", accountId: "a1")]
        )
        #expect(plan.watchIdsToDelete.isEmpty)
        #expect(plan.accountIdsToRegister == ["a2"])
        #expect(plan.watchIdsToAdoptLocally.isEmpty)
        #expect(plan.accountIdsToForgetLocally.isEmpty)
    }

    @Test("a local map entry pointing at the wrong (or no) watch id is repaired to match the relay")
    func adoptsRelayWatchIdLocally() {
        let plan = WatchReconciler.plan(
            localPasswordAccountIds: ["a1", "a2"],
            localWatchMap: ["a1": "stale-w1"],
            serverWatches: [summary(watchId: "w1", accountId: "a1"), summary(watchId: "w2", accountId: "a2")]
        )
        #expect(plan.watchIdsToDelete.isEmpty)
        #expect(plan.accountIdsToRegister.isEmpty)
        #expect(plan.watchIdsToAdoptLocally == ["a1": "w1", "a2": "w2"])
        #expect(plan.accountIdsToForgetLocally.isEmpty)
    }

    @Test("a duplicate second watch for the same account is deleted, keeping only the first")
    func deletesDuplicateWatch() {
        let plan = WatchReconciler.plan(
            localPasswordAccountIds: ["a1"],
            localWatchMap: ["a1": "w1"],
            serverWatches: [summary(watchId: "w1", accountId: "a1"), summary(watchId: "w1-dup", accountId: "a1")]
        )
        #expect(plan.watchIdsToDelete == ["w1-dup"])
        #expect(plan.accountIdsToRegister.isEmpty)
        #expect(plan.watchIdsToAdoptLocally.isEmpty)
    }

    @Test("no local accounts and no server watches — no-op")
    func noOpWhenEverythingEmpty() {
        let plan = WatchReconciler.plan(localPasswordAccountIds: [], localWatchMap: [:], serverWatches: [])
        #expect(plan.isEmpty)
    }
}
