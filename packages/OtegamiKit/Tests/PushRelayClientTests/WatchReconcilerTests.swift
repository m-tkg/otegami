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

    // MARK: - watchIdsToDelete(forReregisteringAccountId:serverWatches:localWatchId:)

    @Test("reregister: the relay's own watch for this account is queued for deletion even with no local record of it")
    func reregisterDeletesOrphanedServerWatchWithNoLocalRecord() {
        // The actual Task #174 orphan: a previous register/reregister
        // attempt created a watch on the relay but the app never
        // persisted its id locally (crash, kill, or a `try?`-swallowed
        // failure elsewhere) — `localWatchId` is `nil`, but the relay
        // list still has it.
        let watchIds = WatchReconciler.watchIdsToDelete(
            forReregisteringAccountId: "a1",
            serverWatches: [summary(watchId: "w1-orphan", accountId: "a1")],
            localWatchId: nil
        )
        #expect(watchIds == ["w1-orphan"])
    }

    @Test("reregister: only watches for the target account are selected, other accounts' watches are left alone")
    func reregisterIgnoresOtherAccountsWatches() {
        let watchIds = WatchReconciler.watchIdsToDelete(
            forReregisteringAccountId: "a1",
            serverWatches: [summary(watchId: "w1", accountId: "a1"), summary(watchId: "w2", accountId: "a2")],
            localWatchId: nil
        )
        #expect(watchIds == ["w1"])
    }

    @Test("reregister: the local map's watch id is included even if the relay list doesn't have it (e.g. a failed GET /v1/watches)")
    func reregisterFallsBackToLocalWatchId() {
        let watchIds = WatchReconciler.watchIdsToDelete(
            forReregisteringAccountId: "a1",
            serverWatches: [],
            localWatchId: "w1-local-only"
        )
        #expect(watchIds == ["w1-local-only"])
    }

    @Test("reregister: a duplicate server watch and the local map's watch id for the same account are unioned, not double-counted")
    func reregisterUnionsServerAndLocalWatchIds() {
        let watchIds = WatchReconciler.watchIdsToDelete(
            forReregisteringAccountId: "a1",
            serverWatches: [summary(watchId: "w1", accountId: "a1"), summary(watchId: "w1-dup", accountId: "a1")],
            localWatchId: "w1"
        )
        #expect(watchIds == ["w1", "w1-dup"])
    }

    @Test("reregister: nothing to delete when neither the relay nor the local map knows of a watch for this account")
    func reregisterNoWatchesToDeleteWhenNoneExist() {
        let watchIds = WatchReconciler.watchIdsToDelete(
            forReregisteringAccountId: "a1",
            serverWatches: [],
            localWatchId: nil
        )
        #expect(watchIds.isEmpty)
    }

    // MARK: - watchIdsToDeleteForDisable(serverWatches:localWatchMap:)

    @Test("disable: every relay watch for this device is included, even ones the local map never learned about")
    func disableIncludesEveryServerWatch() {
        let watchIds = WatchReconciler.watchIdsToDeleteForDisable(
            serverWatches: [summary(watchId: "w1", accountId: "a1"), summary(watchId: "w2-orphan", accountId: "a2")],
            localWatchMap: ["a1": "w1"]
        )
        #expect(watchIds == ["w1", "w2-orphan"])
    }

    @Test("disable: the local map's watch ids are still included when the relay list call failed (empty serverWatches)")
    func disableFallsBackToLocalWatchMap() {
        let watchIds = WatchReconciler.watchIdsToDeleteForDisable(
            serverWatches: [],
            localWatchMap: ["a1": "w1", "a2": "w2"]
        )
        #expect(watchIds == ["w1", "w2"])
    }

    @Test("disable: nothing to delete when both the relay and the local map are empty")
    func disableNoWatchesToDeleteWhenNoneExist() {
        let watchIds = WatchReconciler.watchIdsToDeleteForDisable(serverWatches: [], localWatchMap: [:])
        #expect(watchIds.isEmpty)
    }
}
