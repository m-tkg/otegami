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

    // MARK: - Identity-based duplicate prevention (docs/icloud-sync.md
    // "重複挿入バグ": two devices independently adding "the same" mail
    // account each mint their own `accountId` UUID, so matching on
    // `accountId` alone used to insert both as unrelated accounts).

    /// The core repro from the real device report: this device already has
    /// the account locally (its own UUID); the cloud payload separately
    /// carries a second copy of the *same* mailbox (same email/imapHost/
    /// imapUsername) under a different UUID, pushed by another device.
    /// `reconcile()` must not insert that second copy as a new account.
    ///
    /// `imapHost` here is deliberately *not* the real `imap.otegami.test`
    /// dev-mailstack host the original bug report used — `.test` domains
    /// are now excluded from cloud sync entirely (`CloudAccountSnapshot
    /// .isDevelopmentAccount`'s doc comment, added after this test), which
    /// would make phase 4 purge these fixtures instead of exercising the
    /// duplicate-detection logic this test is actually about.
    @Test
    func reconcileDoesNotInsertACloudDuplicateOfAnAccountAlreadyLocal() async {
        let store = FakeUbiquitousStore()
        let local = FakeLocalAccountDirectory()
        local.seedLocalAccount(.fixture(accountId: "device-a-uuid", email: "test1@otegami.test", imapHost: "imap.otegami-mail.example", updatedAt: epoch))
        // Another device's copy of the exact same mailbox, different UUID,
        // not yet known to this device and not tombstoned.
        store.seed(AccountCloudPayload(accounts: [
            .fixture(accountId: "device-b-uuid", email: "test1@otegami.test", imapHost: "imap.otegami-mail.example", updatedAt: epoch)
        ]))
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.insertedAccounts.isEmpty)
        #expect(summary.duplicateCloudAccountIds == ["device-b-uuid"])
        #expect(local.insertedAccounts.isEmpty)
        // Only the original local account exists afterward — no duplicate
        // row, no duplicate mail source.
        #expect(await local.allAccountSnapshots().map(\.accountId) == ["device-a-uuid"])
    }

    /// A brand-new third device (no local copy of either) reconciling a
    /// payload that already carries two duplicate UUIDs for the same
    /// mailbox (left over from before this fix, or from two devices racing
    /// to add the account before either saw the other's push) must insert
    /// exactly one of them — never both — and every device reconciling the
    /// same payload must agree on *which* one, hence the `accountId`-sorted
    /// iteration order.
    @Test
    func reconcileInsertsOnlyOneOfTwoDuplicateCloudAccountsWithNoLocalCopyAtAll() async {
        let store = FakeUbiquitousStore()
        store.seed(AccountCloudPayload(accounts: [
            .fixture(accountId: "zzz-later", email: "test1@otegami.test", imapHost: "imap.otegami-mail.example", updatedAt: epoch),
            .fixture(accountId: "aaa-earlier", email: "test1@otegami.test", imapHost: "imap.otegami-mail.example", updatedAt: epoch)
        ]))
        let local = FakeLocalAccountDirectory()
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.insertedAccounts.map(\.accountId) == ["aaa-earlier"])
        #expect(summary.duplicateCloudAccountIds == ["zzz-later"])
        #expect(local.insertedAccounts.count == 1)
    }

    /// Different email/host/username entirely — not a duplicate, both must
    /// still insert normally. Guards against the identity check being too
    /// aggressive.
    @Test
    func reconcileStillInsertsGenuinelyDifferentCloudAccounts() async {
        let store = FakeUbiquitousStore()
        let local = FakeLocalAccountDirectory()
        local.seedLocalAccount(.fixture(accountId: "local-work", email: "work@otegami.test", imapHost: "imap.otegami-mail.example", updatedAt: epoch))
        store.seed(AccountCloudPayload(accounts: [
            .fixture(accountId: "cloud-personal", email: "personal@otegami.test", imapHost: "imap.otegami-mail.example", updatedAt: epoch)
        ]))
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.insertedAccounts.map(\.accountId) == ["cloud-personal"])
        #expect(summary.duplicateCloudAccountIds.isEmpty)
    }

    /// Same email/host but a different `authType` (e.g. a `.password`
    /// account that coincidentally shares an address with an `.oauth2`
    /// one) must never be merged — see `identityKey`'s doc comment on why
    /// `authType` is part of the guard.
    @Test
    func reconcileDoesNotTreatDifferentAuthTypesAsDuplicatesEvenWithMatchingEmailAndHost() async {
        let store = FakeUbiquitousStore()
        let local = FakeLocalAccountDirectory()
        local.seedLocalAccount(
            .fixture(accountId: "local-password", email: "same@otegami.test", authType: .password, imapHost: "imap.otegami-mail.example", updatedAt: epoch)
        )
        store.seed(AccountCloudPayload(accounts: [
            .fixture(accountId: "cloud-oauth2", email: "same@otegami.test", authType: .oauth2, imapHost: "imap.otegami-mail.example", updatedAt: epoch)
        ]))
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.insertedAccounts.map(\.accountId) == ["cloud-oauth2"])
        #expect(summary.duplicateCloudAccountIds.isEmpty)
    }

    // MARK: - Development/test account exclusion (docs/icloud-sync.md
    // "開発用アカウントの除外": a Mac used for local development shares the
    // exact same iCloud KVS identifier — and the same, real, signed-in
    // Apple ID — as an Ad-Hoc-signed real-device build, so a dev-mailstack
    // account (LAN/loopback IMAP host, or `.test`/`.local` domain) must
    // never reach the real cloud payload.)

    @Test
    func pushLocalChangeSkipsADevelopmentAccount() async {
        let store = FakeUbiquitousStore()
        let local = FakeLocalAccountDirectory()
        let engine = makeEngine(store: store, local: local)

        await engine.pushLocalChange(.fixture(accountId: "dev-1", imapHost: "192.168.0.163", updatedAt: epoch))

        #expect(store.currentPayload() == nil)
        #expect(store.setCallCount == 0)
    }

    @Test
    func reconcileNeverPushesALocalDevelopmentAccountToTheCloud() async {
        let store = FakeUbiquitousStore()
        let local = FakeLocalAccountDirectory()
        local.seedLocalAccount(.fixture(accountId: "dev-2", imapHost: "test1.otegami.test", updatedAt: epoch))
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.pushedAccountIds.isEmpty)
        #expect(store.currentPayload() == nil)
        #expect(store.setCallCount == 0)
    }

    /// The self-healing half: a development account already sitting in the
    /// cloud payload (pushed before this exclusion existed, or by another
    /// dev/Simulator machine sharing the same Apple ID) must be scrubbed
    /// out — not inserted locally — the next time *any* device reconciles,
    /// regardless of whether that device has a local copy of it or not.
    @Test
    func reconcilePurgesADevelopmentAccountFoundOnlyInTheCloudInsteadOfInsertingIt() async {
        let store = FakeUbiquitousStore()
        store.seed(AccountCloudPayload(accounts: [
            .fixture(accountId: "contaminated-1", imapHost: "192.168.0.163", updatedAt: epoch),
            .fixture(accountId: "real-1", imapHost: "imap.gmail.com", updatedAt: epoch)
        ]))
        let local = FakeLocalAccountDirectory()
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.purgedDevelopmentAccountIds == ["contaminated-1"])
        #expect(summary.insertedAccounts.map(\.accountId) == ["real-1"])
        #expect(local.insertedAccounts.map(\.snapshot.accountId) == ["real-1"])
        #expect(store.currentPayload()?.accounts.map(\.accountId) == ["real-1"])
    }

    /// Covers the exact end state a real device was left in: this device
    /// already has a local `AccountRecord` row for the dev account (from
    /// before the fix), and the cloud payload also still carries it. The
    /// local row is left completely untouched (the user still deletes it
    /// by hand, same as any other unwanted account) — only the cloud
    /// payload entry is purged, so it can never be re-synced down again
    /// after that manual deletion.
    @Test
    func reconcileLeavesAnExistingLocalDevelopmentAccountUntouchedWhilePurgingItsCloudEntry() async {
        let store = FakeUbiquitousStore()
        let devSnapshot = CloudAccountSnapshot.fixture(accountId: "dev-3", displayName: "Dovecot Test1", imapHost: "localhost", updatedAt: epoch)
        store.seed(AccountCloudPayload(accounts: [devSnapshot]))
        let local = FakeLocalAccountDirectory()
        local.seedLocalAccount(devSnapshot)
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.purgedDevelopmentAccountIds == ["dev-3"])
        #expect(summary.deletedAccountIds.isEmpty, "the existing local row must not be deleted by this cleanup")
        #expect(local.deletedAccountIds.isEmpty)
        #expect(local.currentAccount("dev-3") != nil, "the local row survives — only the cloud entry is purged")
        #expect(store.currentPayload()?.accounts.isEmpty == true)
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

    // MARK: - Account edit propagation (account edit UI:
    // "編集 → cloud push → 別デバイス相当の reconcile で反映される、逆に古い
    // updatedAt の cloud データでローカルの新しい編集が上書きされない")

    /// Simulates device A editing an account (host/port/SMTP username all
    /// change, `updatedAt` bumped) and pushing it, then device B's next
    /// `reconcile()` picking up that edit — the exact mechanism
    /// `AppEnvironment.updateAccount`/`pushAccountToCloud` and this engine's
    /// `reconcile()` phase 3 already implement; this test just exercises it
    /// with every editable field changed at once; `apply(to:)`'s own
    /// completeness is separately guaranteed by
    /// `OtegamiStore`'s round-trip, this test is about the sync mechanism.
    @Test
    func reconcileAppliesAnEditedAccountFromANewerCloudSnapshotOnAnotherDevice() async {
        let store = FakeUbiquitousStore()
        let local = FakeLocalAccountDirectory()
        // Device A's pre-edit copy, still what device B has locally.
        local.seedLocalAccount(
            CloudAccountSnapshot(
                accountId: "edited-1",
                displayName: "Old Name",
                email: "user@example.com",
                authType: .password,
                kind: .generic,
                imapHost: "old-imap.example.com",
                imapPort: 993,
                imapSecurity: .tls,
                imapAllowsInsecureTLS: false,
                imapUsername: "user@example.com",
                smtpHost: "old-smtp.example.com",
                smtpPort: 465,
                smtpSecurity: .tls,
                smtpAllowsInsecureTLS: false,
                smtpUsername: "user@example.com",
                createdAt: epoch,
                updatedAt: epoch
            )
        )
        // Device A's edit, already pushed to the cloud with a newer
        // `updatedAt` — every editable field (per the account-edit plan:
        // display name, IMAP/SMTP host/port/security, SMTP username)
        // changed at once.
        let editedSnapshot = CloudAccountSnapshot(
            accountId: "edited-1",
            displayName: "New Name",
            email: "user@example.com",
            authType: .password,
            kind: .generic,
            imapHost: "new-imap.example.com",
            imapPort: 143,
            imapSecurity: .startTLS,
            imapAllowsInsecureTLS: false,
            imapUsername: "user@example.com",
            smtpHost: "new-smtp.example.com",
            smtpPort: 587,
            smtpSecurity: .startTLS,
            smtpAllowsInsecureTLS: false,
            smtpUsername: "new-smtp-user@example.com",
            createdAt: epoch,
            updatedAt: epoch.addingTimeInterval(100)
        )
        store.seed(AccountCloudPayload(accounts: [editedSnapshot]))
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.updatedAccountIds == ["edited-1"])
        let updated = local.currentAccount("edited-1")
        #expect(updated?.displayName == "New Name")
        #expect(updated?.imapHost == "new-imap.example.com")
        #expect(updated?.imapPort == 143)
        #expect(updated?.imapSecurity == .startTLS)
        #expect(updated?.smtpHost == "new-smtp.example.com")
        #expect(updated?.smtpPort == 587)
        #expect(updated?.smtpSecurity == .startTLS)
        #expect(updated?.smtpUsername == "new-smtp-user@example.com")
    }

    /// The reverse of the test above: a *stale* cloud copy (edited on some
    /// other device a while ago, or just never caught up) must not clobber
    /// a local edit that happened more recently — `reconcile()` should push
    /// the newer local edit up instead.
    @Test
    func reconcileKeepsANewerLocalEditRatherThanAnOlderCloudCopy() async {
        let store = FakeUbiquitousStore()
        let staleCloud = CloudAccountSnapshot.fixture(
            accountId: "edited-2",
            displayName: "Stale Cloud Name",
            imapHost: "stale.example.com",
            updatedAt: epoch
        )
        store.seed(AccountCloudPayload(accounts: [staleCloud]))
        let local = FakeLocalAccountDirectory()
        // Local was just edited (e.g. a password/host fix) after the stale
        // cloud snapshot above was written.
        local.seedLocalAccount(
            CloudAccountSnapshot.fixture(
                accountId: "edited-2",
                displayName: "Freshly Edited Name",
                imapHost: "fresh.example.com",
                updatedAt: epoch.addingTimeInterval(100)
            )
        )
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.pushedAccountIds == ["edited-2"])
        #expect(summary.updatedAccountIds.isEmpty)
        // Local's edit must survive untouched...
        #expect(local.currentAccount("edited-2")?.displayName == "Freshly Edited Name")
        #expect(local.currentAccount("edited-2")?.imapHost == "fresh.example.com")
        // ...and the cloud payload must now reflect it too, not the stale
        // copy it started with.
        let pushedAccount = store.currentPayload()?.accounts.first { $0.accountId == "edited-2" }
        #expect(pushedAccount?.displayName == "Freshly Edited Name")
        #expect(pushedAccount?.imapHost == "fresh.example.com")
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
