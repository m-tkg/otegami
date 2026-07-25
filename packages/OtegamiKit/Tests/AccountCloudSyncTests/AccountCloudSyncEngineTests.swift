import Foundation
import Testing
import OtegamiStore
@testable import AccountCloudSync

@Suite("AccountCloudSyncEngine")
struct AccountCloudSyncEngineTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEngine(
        store: FakeUbiquitousStore = FakeUbiquitousStore(),
        local: FakeLocalAccountDirectory = FakeLocalAccountDirectory(),
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) },
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) -> AccountCloudSyncEngine {
        AccountCloudSyncEngine(store: store, local: local, now: now, isEnabled: isEnabled)
    }

    // MARK: - Local → cloud push

    @Test
    func reconcilePushesALocalOnlyAccountToTheCloud() async {
        let store = FakeUbiquitousStore()
        let local = FakeLocalAccountDirectory()
        local.seedLocalAccount(.fixture(accountId: "local-1", updatedAt: epoch))
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.pushedAccountIds == ["local-1"])
        #expect(store.currentPayload()?.accounts.map(\.accountId) == ["local-1"])
    }

    /// Also covers "initial migration": a device's entire pre-existing
    /// account list (never touched iCloud sync before this feature) gets
    /// pushed up the very first time `reconcile()` runs, via the exact same
    /// "local account with no cloud counterpart yet" branch.
    @Test
    func reconcileMigratesEveryPreExistingLocalAccountOnFirstRun() async {
        let store = FakeUbiquitousStore()
        let local = FakeLocalAccountDirectory()
        local.seedLocalAccount(.fixture(accountId: "old-1", updatedAt: epoch))
        local.seedLocalAccount(.fixture(accountId: "old-2", updatedAt: epoch))
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(Set(summary.pushedAccountIds) == ["old-1", "old-2"])
        #expect(Set(store.currentPayload()?.accounts.map(\.accountId) ?? []) == ["old-1", "old-2"])
    }

    @Test
    func pushLocalChangeWritesImmediatelyWithoutAFullReconcile() async {
        let store = FakeUbiquitousStore()
        let local = FakeLocalAccountDirectory()
        let engine = makeEngine(store: store, local: local)

        await engine.pushLocalChange(.fixture(accountId: "new-1", updatedAt: epoch))

        #expect(store.currentPayload()?.accounts.map(\.accountId) == ["new-1"])
        #expect(store.setCallCount == 1)
    }

    // MARK: - Cloud → local insertion

    @Test
    func reconcileInsertsACloudOnlyAccountWithACredentialAlreadyOnThisDevice() async {
        let store = FakeUbiquitousStore()
        store.seed(AccountCloudPayload(accounts: [.fixture(accountId: "cloud-1", updatedAt: epoch)]))
        let local = FakeLocalAccountDirectory()
        local.setCredential(true, forAccountId: "cloud-1")
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.insertedAccounts == [.init(accountId: "cloud-1", hasCredential: true)])
        #expect(local.insertedAccounts.count == 1)
        #expect(local.insertedAccounts[0].hasCredential == true)
    }

    @Test
    func reconcileInsertsACloudOnlyAccountWithNoCredentialYetOnThisDevice() async {
        let store = FakeUbiquitousStore()
        store.seed(AccountCloudPayload(accounts: [.fixture(accountId: "cloud-2", updatedAt: epoch)]))
        let local = FakeLocalAccountDirectory()
        // No `setCredential` call — this device's Keychain has nothing for
        // "cloud-2" yet (iCloud Keychain sync hasn't caught up).
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.insertedAccounts == [.init(accountId: "cloud-2", hasCredential: false)])
        #expect(local.insertedAccounts[0].hasCredential == false)
    }

    // MARK: - Tombstone deletion propagation

    @Test
    func reconcileDeletesALocalAccountThatWasTombstonedElsewhere() async {
        let store = FakeUbiquitousStore()
        store.seed(AccountCloudPayload(tombstones: [AccountTombstone(accountId: "gone-1", deletedAt: epoch)]))
        let local = FakeLocalAccountDirectory()
        local.seedLocalAccount(.fixture(accountId: "gone-1", updatedAt: epoch.addingTimeInterval(-3600)))
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.deletedAccountIds == ["gone-1"])
        #expect(local.deletedAccountIds == ["gone-1"])
        #expect(await local.allAccountSnapshots().isEmpty)
    }

    @Test
    func pushLocalDeletionRecordsATombstoneAndRemovesTheAccountEntry() async {
        let store = FakeUbiquitousStore()
        store.seed(AccountCloudPayload(accounts: [.fixture(accountId: "to-delete", updatedAt: epoch)]))
        let local = FakeLocalAccountDirectory()
        let engine = makeEngine(store: store, local: local, now: { self.epoch.addingTimeInterval(10) })

        await engine.pushLocalDeletion(accountId: "to-delete")

        let payload = store.currentPayload()
        #expect(payload?.accounts.isEmpty == true)
        #expect(payload?.tombstones.map(\.accountId) == ["to-delete"])
        #expect(payload?.tombstones.first?.deletedAt == epoch.addingTimeInterval(10))
    }

    // MARK: - Last-writer-wins

    @Test
    func reconcileLetsANewerCloudCopyOverwriteAnOlderLocalCopy() async {
        let store = FakeUbiquitousStore()
        let newerCloud = CloudAccountSnapshot.fixture(accountId: "conflict-1", displayName: "Cloud Wins", updatedAt: epoch.addingTimeInterval(100))
        store.seed(AccountCloudPayload(accounts: [newerCloud]))
        let local = FakeLocalAccountDirectory()
        local.seedLocalAccount(.fixture(accountId: "conflict-1", displayName: "Local Stale", updatedAt: epoch))
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.updatedAccountIds == ["conflict-1"])
        #expect(local.currentAccount("conflict-1")?.displayName == "Cloud Wins")
        #expect(summary.pushedAccountIds.isEmpty)
    }

    @Test
    func reconcileLetsANewerLocalCopyOverwriteAnOlderCloudCopy() async {
        let store = FakeUbiquitousStore()
        let olderCloud = CloudAccountSnapshot.fixture(accountId: "conflict-2", displayName: "Cloud Stale", updatedAt: epoch)
        store.seed(AccountCloudPayload(accounts: [olderCloud]))
        let local = FakeLocalAccountDirectory()
        local.seedLocalAccount(.fixture(accountId: "conflict-2", displayName: "Local Wins", updatedAt: epoch.addingTimeInterval(100)))
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.pushedAccountIds == ["conflict-2"])
        #expect(store.currentPayload()?.accounts.first?.displayName == "Local Wins")
        #expect(summary.updatedAccountIds.isEmpty)
    }

    @Test
    func reconcileDoesNothingWhenBothCopiesAgree() async {
        let store = FakeUbiquitousStore()
        let snapshot = CloudAccountSnapshot.fixture(accountId: "same-1", updatedAt: epoch)
        store.seed(AccountCloudPayload(accounts: [snapshot]))
        let local = FakeLocalAccountDirectory()
        local.seedLocalAccount(snapshot)
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.updatedAccountIds.isEmpty)
        #expect(summary.pushedAccountIds.isEmpty)
        #expect(summary.insertedAccounts.isEmpty)
        // Tombstone pruning still ran (no tombstones here, so nothing
        // changed) but nothing about the accounts list needed rewriting —
        // the store shouldn't have been written to at all.
        #expect(store.setCallCount == 0)
    }

    // MARK: - Toggle off

    @Test
    func reconcileDoesNothingWhenDisabled() async {
        let store = FakeUbiquitousStore()
        store.seed(AccountCloudPayload(accounts: [.fixture(accountId: "cloud-only", updatedAt: epoch)]))
        let local = FakeLocalAccountDirectory()
        local.seedLocalAccount(.fixture(accountId: "local-only", updatedAt: epoch))
        let engine = makeEngine(store: store, local: local, isEnabled: { false })

        let summary = await engine.reconcile()

        #expect(summary == .disabled)
        #expect(local.insertedAccounts.isEmpty)
        #expect(store.setCallCount == 0)
        // The local-only account is untouched — still there, never pushed.
        #expect(await local.allAccountSnapshots().map(\.accountId) == ["local-only"])
    }

    @Test
    func pushLocalChangeDoesNothingWhenDisabled() async {
        let store = FakeUbiquitousStore()
        let local = FakeLocalAccountDirectory()
        let engine = makeEngine(store: store, local: local, isEnabled: { false })

        await engine.pushLocalChange(.fixture(accountId: "ignored", updatedAt: epoch))

        #expect(store.currentPayload() == nil)
    }

    @Test
    func pushLocalDeletionDoesNothingWhenDisabled() async {
        let store = FakeUbiquitousStore()
        store.seed(AccountCloudPayload(accounts: [.fixture(accountId: "still-there", updatedAt: epoch)]))
        let local = FakeLocalAccountDirectory()
        let engine = makeEngine(store: store, local: local, isEnabled: { false })

        await engine.pushLocalDeletion(accountId: "still-there")

        #expect(store.currentPayload()?.accounts.map(\.accountId) == ["still-there"])
        #expect(store.currentPayload()?.tombstones.isEmpty == true)
    }

    // MARK: - Actor-reentrancy race (docs/qa-findings.md: intermittent
    // "just-added account briefly reverts" during back-to-back account
    // adds)

    /// Reproduces, deterministically, the lost-update race
    /// `AccountCloudSyncEngine`'s payload lock (see its doc comment) fixes:
    /// a `pushLocalChange` that lands on the actor *while* a `reconcile()`
    /// call is suspended mid-flight (after `reconcile()` already loaded the
    /// cloud payload, but before it's done recomputing/saving it) must not
    /// have its write silently clobbered when `reconcile()` resumes and
    /// saves its own, now-stale, view of the payload.
    ///
    /// Without the fix, this fails: `reconcile()`'s final `savePayload`
    /// overwrites `pushLocalChange`'s write with a payload that never saw
    /// "concurrent-push", because `reconcile()` loaded the payload *before*
    /// the concurrent push happened and never re-reads it before saving.
    @Test
    func concurrentPushDuringReconcileDoesNotLoseTheUpdate() async {
        let store = FakeUbiquitousStore()
        let local = FakeLocalAccountDirectory()
        // A local-only account with no cloud counterpart guarantees
        // reconcile()'s phase 3 marks the payload changed and actually
        // calls savePayload at the end (see reconcileDoesNothingWhenBothCopiesAgree
        // above for the case where it doesn't) — that final save is what
        // needs to observe the concurrent push rather than clobber it.
        local.seedLocalAccount(.fixture(accountId: "existing", updatedAt: epoch))

        let reachedPauseGate = AsyncGate()
        let releaseGate = AsyncGate()
        local.onAllAccountSnapshots = {
            await reachedPauseGate.open()
            await releaseGate.wait()
        }

        let engine = makeEngine(store: store, local: local)

        let reconcileTask = Task { await engine.reconcile() }
        // Wait until reconcile() has loaded the payload and is genuinely
        // suspended inside allAccountSnapshots() — not a fixed sleep, so
        // this half of the sequencing is exact.
        await reachedPauseGate.wait()

        let pushTask = Task {
            await engine.pushLocalChange(.fixture(accountId: "concurrent-push", updatedAt: epoch))
        }
        // No signal exists for "pushTask's call has reached the actor's
        // queue" without instrumenting production code further, so this
        // bridges that one gap with a bounded sleep — 200ms is orders of
        // magnitude more than Swift's cooperative thread pool needs to
        // dequeue a Task onto an idle actor, and long enough for the
        // unfixed code's pushLocalChange (no internal suspension points at
        // all) to run to completion before the gate opens, which is what
        // makes this test actually exercise the race instead of vacuously
        // passing.
        try? await Task.sleep(nanoseconds: 200_000_000)

        await releaseGate.open()
        _ = await reconcileTask.value
        await pushTask.value

        let payload = store.currentPayload()
        let ids = Set(payload?.accounts.map(\.accountId) ?? [])
        #expect(ids.contains("concurrent-push"), "pushLocalChange's write must survive a reconcile() that was mid-flight when it landed")
        #expect(ids.contains("existing"), "reconcile()'s own migration of the local-only account must still take effect")
    }

    // MARK: - Tombstone retention

    @Test
    func reconcilePurgesTombstonesOlderThanTheRetentionWindow() async {
        let store = FakeUbiquitousStore()
        let retention: TimeInterval = 90 * 24 * 3600
        let oldTombstone = AccountTombstone(accountId: "ancient", deletedAt: epoch.addingTimeInterval(-retention - 3600))
        let recentTombstone = AccountTombstone(accountId: "recent", deletedAt: epoch.addingTimeInterval(-3600))
        store.seed(AccountCloudPayload(tombstones: [oldTombstone, recentTombstone]))
        let local = FakeLocalAccountDirectory()
        let engine = makeEngine(store: store, local: local, now: { self.epoch }, isEnabled: { true })

        _ = await engine.reconcile()

        let remainingIds = store.currentPayload()?.tombstones.map(\.accountId) ?? []
        #expect(remainingIds == ["recent"])
    }

    @Test
    func reconcileKeepsTombstonesWithinTheRetentionWindowAndDoesNotRewriteWhenNothingChanged() async {
        let store = FakeUbiquitousStore()
        store.seed(AccountCloudPayload(tombstones: [AccountTombstone(accountId: "recent", deletedAt: epoch)]))
        let local = FakeLocalAccountDirectory()
        let engine = makeEngine(store: store, local: local, now: { self.epoch.addingTimeInterval(3600) })

        _ = await engine.reconcile()

        #expect(store.currentPayload()?.tombstones.map(\.accountId) == ["recent"])
        #expect(store.setCallCount == 0)
    }
}
