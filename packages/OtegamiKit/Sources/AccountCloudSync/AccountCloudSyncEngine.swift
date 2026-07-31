import Foundation
import OtegamiStore

/// What `AccountCloudSyncEngine.reconcile()` actually did, for callers that
/// need to react (start a first sync for a newly-inserted account, stop an
/// `IDLE` loop for a deleted one) and for tests to assert against without
/// reaching into the engine's private state.
public struct ReconcileSummary: Equatable, Sendable {
    public struct InsertedAccount: Equatable, Sendable {
        public let accountId: String
        /// Whether `LocalAccountDirectory.hasCredential` found a usable
        /// credential already on this device — if so, the caller should
        /// start syncing immediately; if not, the account was inserted with
        /// `needsReauth` set (the "waiting for a credential" banner) and
        /// there is nothing more to do until the user retries or Keychain
        /// sync delivers the password.
        public let hasCredential: Bool
    }

    public var insertedAccounts: [InsertedAccount] = []
    public var updatedAccountIds: [String] = []
    public var deletedAccountIds: [String] = []
    public var pushedAccountIds: [String] = []
    /// Cloud-only accounts (phase 4) that were *not* inserted because their
    /// `CloudAccountSnapshot.identityKey` already matched an account this
    /// device knows about (locally, or another cloud account already
    /// claimed by this same pass) under a different `accountId` — see
    /// `identityKey`'s doc comment for the duplicate-insertion bug this
    /// prevents. Exposed mainly for tests to assert the dedup actually
    /// fired; app code has no separate action to take for these (unlike
    /// `insertedAccounts`) since by definition nothing changed locally.
    public var duplicateCloudAccountIds: [String] = []
    /// Cloud-only accounts `reconcile()`'s phase 4 recognized as
    /// development/test accounts (`CloudAccountSnapshot
    /// .isDevelopmentAccount` — a LAN/loopback IMAP host, or a `.test`/
    /// `.local` domain) sitting in the KVS payload — never inserted
    /// locally, and stripped out of the payload that gets saved back
    /// instead, so this is also the mechanism that self-heals an already-
    /// contaminated cloud payload (`docs/icloud-sync.md`'s "開発用アカウン
    /// トの除外"): every device's next `reconcile()` scrubs any dev
    /// account entry it finds, regardless of which device originally
    /// pushed it or when.
    public var purgedDevelopmentAccountIds: [String] = []
    /// `true` when `reconcile()` short-circuited because iCloud account sync
    /// is toggled off (`AccountCloudSyncEngine.isEnabled`) — every other
    /// field is empty in that case, since nothing was looked at at all.
    public var disabled = false

    public init(
        insertedAccounts: [InsertedAccount] = [],
        updatedAccountIds: [String] = [],
        deletedAccountIds: [String] = [],
        pushedAccountIds: [String] = [],
        duplicateCloudAccountIds: [String] = [],
        purgedDevelopmentAccountIds: [String] = [],
        disabled: Bool = false
    ) {
        self.insertedAccounts = insertedAccounts
        self.updatedAccountIds = updatedAccountIds
        self.deletedAccountIds = deletedAccountIds
        self.pushedAccountIds = pushedAccountIds
        self.duplicateCloudAccountIds = duplicateCloudAccountIds
        self.purgedDevelopmentAccountIds = purgedDevelopmentAccountIds
        self.disabled = disabled
    }

    public static let disabled = ReconcileSummary(disabled: true)
}

/// Owns the `"accounts.v1"` iCloud KVS key: reconciling it against the
/// local `account` table (`reconcile()`, run at launch and whenever
/// `NSUbiquitousKeyValueStore.didChangeExternallyNotification` fires — the
/// app layer owns subscribing to that notification and calling
/// `reconcile()` again, since the notification itself isn't something a
/// unit test should depend on) and pushing local changes as they happen
/// (`pushLocalChange`/`pushLocalDeletion`, called right after a local
/// account add/edit/delete).
///
/// An `actor` (not `@MainActor`) because every operation here is either
/// pure data-juggling or `await`s onto `LocalAccountDirectory`/
/// `UbiquitousStoring` — nothing UI-related — matching `GoogleOAuth
/// .TokenStore`'s reasoning for the same choice.
public actor AccountCloudSyncEngine {
    /// `NSUbiquitousKeyValueStore` caps a single key's value at roughly
    /// 64KB (and total storage at 1MB) — see Apple's documentation.
    /// Comfortably out of reach for the account counts this app is ever
    /// realistically going to manage (a JSON snapshot of a few dozen
    /// accounts is a few KB), but a corrupted/runaway payload (e.g. a
    /// tombstone-purge bug that never actually purges) filling the key
    /// past the real limit would make the *next* write silently fail
    /// system-side and could wedge iCloud sync for every key this app
    /// uses, not just this one. `savePayload` refuses to write past this
    /// threshold instead, leaving the previous (smaller, still valid)
    /// cloud payload in place rather than risking that.
    public static let maxPayloadBytes = 60_000

    private static let payloadKey = "accounts.v1"

    private let store: any UbiquitousStoring
    private let local: any LocalAccountDirectory
    private let tombstoneRetention: TimeInterval
    private let now: @Sendable () -> Date
    private let isEnabled: @Sendable () -> Bool

    /// Guards the "load the `accounts.v1` payload, mutate it, save it back"
    /// critical section shared by `reconcile()`/`pushLocalChange`/
    /// `pushLocalDeletion` against Swift's **actor reentrancy**: an `actor`
    /// only serializes its methods *between* suspension points, not across
    /// one. `reconcile()` in particular awaits `local.allAccountSnapshots()`
    /// (a real suspension point — it reads GRDB) *after* already calling
    /// `loadPayload()`, so without this lock a `pushLocalChange`/
    /// `pushLocalDeletion` call that arrives at this same actor while
    /// `reconcile()` is suspended there is free to run to completion
    /// (load-mutate-save its own payload) *before* `reconcile()` resumes —
    /// `reconcile()` then finishes its own diffing against the `payload` it
    /// already loaded (now stale) and overwrites the store with it,
    /// silently discarding the concurrent push. Confirmed as the root cause
    /// of the intermittent "just-added account briefly reverts to a stale
    /// cloud copy" failures QA sweeping surfaced (see `docs/architecture.md`'s
    /// Known pitfalls) —
    /// reproduced deterministically in
    /// `AccountCloudSyncEngineTests.concurrentPushDuringReconcileDoesNotLoseTheUpdate`
    /// by pausing a fake `local.allAccountSnapshots()` mid-`reconcile()` and
    /// firing a `pushLocalChange` into the gap. This is a real hazard for
    /// actual users too (not just this dev machine's stale iCloud KVS test
    /// data) — e.g. `AppEnvironment.init()`'s launch-time `reconcile()`
    /// racing a user adding an account within the same moment, or racing
    /// the `didChangeExternallyNotification`-triggered `reconcile()` from
    /// another device's concurrent push — so this is a production fix, not
    /// a test-only workaround.
    ///
    /// A plain `NSLock`/`DispatchSemaphore` wouldn't work here (blocking a
    /// thread across an `await` on an actor can deadlock the cooperative
    /// thread pool); this is the standard actor-safe async mutex shape
    /// instead — `acquirePayloadLock()`/`releasePayloadLock()` — built from
    /// first principles rather than a library so `AccountCloudSync` keeps
    /// its zero-dependency footprint.
    private var isPayloadLocked = false
    private var payloadLockWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquirePayloadLock() async {
        if isPayloadLocked {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                payloadLockWaiters.append(continuation)
            }
            // Resumed by `releasePayloadLock()`, which transfers ownership
            // directly to us (leaves `isPayloadLocked` `true`) — nothing
            // more to do here.
            return
        }
        isPayloadLocked = true
    }

    private func releasePayloadLock() {
        guard isPayloadLocked else { return }
        if payloadLockWaiters.isEmpty {
            isPayloadLocked = false
        } else {
            // Hand the lock straight to the next waiter (FIFO) without ever
            // observing `isPayloadLocked == false` in between, so a brand
            // new `acquirePayloadLock()` call arriving right now can't cut
            // the line ahead of whoever's been waiting.
            payloadLockWaiters.removeFirst().resume()
        }
    }

    public init(
        store: any UbiquitousStoring,
        local: any LocalAccountDirectory,
        tombstoneRetention: TimeInterval = 90 * 24 * 3600,
        now: @escaping @Sendable () -> Date = Date.init,
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.store = store
        self.local = local
        self.tombstoneRetention = tombstoneRetention
        self.now = now
        self.isEnabled = isEnabled
    }

    /// Full two-way reconcile: pulls the current cloud payload, diffs it
    /// against every locally-known account, and applies whatever each side
    /// is missing — see the doc comments on the four phases below for the
    /// exact rules. Safe (and cheap — a no-op write) to call repeatedly;
    /// this is both the app-launch entry point and the
    /// `didChangeExternallyNotification`/toggle-flipped-on entry point.
    @discardableResult
    public func reconcile() async -> ReconcileSummary {
        guard isEnabled() else { return .disabled }
        await acquirePayloadLock()
        defer { releasePayloadLock() }

        var summary = ReconcileSummary()
        var payload = loadPayload()
        var payloadChanged = false

        // Phase 1: purge tombstones past the retention window. A tombstone
        // only needs to outlive the longest plausible gap between a
        // deleting device's push and every other device's next reconcile —
        // 90 days (the plan's figure) is far beyond that, so pruning here
        // is just bounding the payload's long-run size, not a correctness
        // requirement for any device that's been reachable at all recently.
        let cutoff = now().addingTimeInterval(-tombstoneRetention)
        let freshTombstones = payload.tombstones.filter { $0.deletedAt > cutoff }
        if freshTombstones.count != payload.tombstones.count { payloadChanged = true }
        payload.tombstones = freshTombstones

        // Development/test accounts (`CloudAccountSnapshot
        // .isDevelopmentAccount`'s doc comment) are kept out of every phase
        // below entirely — excluded here, up front, rather than filtered
        // out of `cloudById`/`payload.accounts` individually, so a local
        // dev account is never considered "missing from the cloud" (phase
        // 3, which would push it) and a tombstone for one is never chased
        // (phase 2 — moot anyway, since one should never have been pushed
        // to generate a tombstone from in the first place). They still
        // exist as ordinary local `AccountRecord` rows outside this engine
        // entirely; this only opts them out of cloud sync bookkeeping.
        let localSnapshots = await local.allAccountSnapshots().filter { !$0.isDevelopmentAccount }
        var localById = Dictionary(uniqueKeysWithValues: localSnapshots.map { ($0.accountId, $0) })
        var cloudById = Dictionary(uniqueKeysWithValues: payload.accounts.map { ($0.accountId, $0) })
        let tombstoneIds = Set(payload.tombstones.map(\.accountId))

        // A tombstoned id has no business lingering in the accounts list
        // itself (it could only get there from a device that pushed before
        // ever seeing the deletion) — drop it from the cloud payload here
        // rather than waiting for whichever device pushed it to notice.
        for id in tombstoneIds where cloudById.removeValue(forKey: id) != nil {
            payloadChanged = true
        }

        // Phase 2: a tombstone for an account this device still has locally
        // means it was deleted elsewhere — delete it here too. Keychain
        // deletion is part of `deleteLocally` (it's a synchronizable item,
        // so this doesn't do anything a real device-to-device Keychain sync
        // wouldn't already have done on its own — see
        // `KeychainCredentialStore`'s doc comment).
        for id in tombstoneIds where localById[id] != nil {
            await local.deleteLocally(accountId: id)
            localById.removeValue(forKey: id)
            summary.deletedAccountIds.append(id)
        }

        // Phase 3: every remaining local account either matches the cloud
        // (nothing to do), is missing from the cloud (push it — this is
        // also how a device's *entire* pre-existing account list gets
        // migrated up the very first time this feature reconciles), or
        // disagrees with the cloud (last-writer-wins by `updatedAt`).
        for (id, localSnapshot) in localById {
            if let cloudSnapshot = cloudById[id] {
                if cloudSnapshot.updatedAt > localSnapshot.updatedAt {
                    await local.updateFromCloud(cloudSnapshot)
                    summary.updatedAccountIds.append(id)
                } else if localSnapshot.updatedAt > cloudSnapshot.updatedAt {
                    cloudById[id] = localSnapshot
                    payloadChanged = true
                    summary.pushedAccountIds.append(id)
                }
                // Equal `updatedAt`: already in sync, nothing to do.
            } else {
                cloudById[id] = localSnapshot
                payloadChanged = true
                summary.pushedAccountIds.append(id)
            }
        }

        // Phase 4: whatever's left in the cloud payload that this device
        // has neither a local copy nor a tombstone for is new — insert it,
        // *unless* it's actually a duplicate of an account this device
        // already has under a different `accountId` (`identityKey`'s doc
        // comment) — two devices independently adding "the same" mail
        // account each generate their own UUID, so id-only matching used to
        // insert both, producing a visible duplicate row in the account
        // list plus duplicate mail (one copy synced per duplicate account)
        // in the unified inbox — the exact bug reported against a real
        // device (`docs/icloud-sync.md`).
        //
        // `claimedIdentities` starts with every surviving local account's
        // identity, then grows as this loop inserts — so a *second* cloud
        // duplicate (e.g. a brand-new device that has neither original
        // locally, reconciling a payload that already carries both UUIDs)
        // only ever inserts the first one it processes, not both. Iterating
        // `cloudById` in a fixed (`accountId`-sorted) order rather than
        // Swift's unspecified `Dictionary` order matters here: without it,
        // two different devices reconciling the exact same payload could
        // each end up "winning" a different duplicate, permanently
        // diverging on which `accountId` is the survivor instead of
        // converging on the same one.
        var claimedIdentities = Set(localById.values.map(\.identityKey))
        for (id, cloudSnapshot) in cloudById.sorted(by: { $0.key < $1.key })
        where localById[id] == nil && !tombstoneIds.contains(id) {
            // Contamination cleanup (`CloudAccountSnapshot
            // .isDevelopmentAccount`'s doc comment,
            // `ReconcileSummary.purgedDevelopmentAccountIds`'s doc
            // comment): a dev/test account sitting in the cloud payload —
            // whether pushed by this device before the exclusion above
            // existed, or by another (dev/Simulator) machine sharing this
            // Apple ID — is never inserted locally. It's removed from
            // `cloudById` (so the payload saved at the end of this method
            // no longer carries it) rather than tombstoned: a tombstone
            // would need to outlive `tombstoneRetention` and gets
            // interpreted as "was deleted, cascade the deletion" by every
            // device, neither of which fits "this entry should simply
            // never have existed".
            guard !cloudSnapshot.isDevelopmentAccount else {
                cloudById.removeValue(forKey: id)
                payloadChanged = true
                summary.purgedDevelopmentAccountIds.append(id)
                continue
            }
            guard !claimedIdentities.contains(cloudSnapshot.identityKey) else {
                summary.duplicateCloudAccountIds.append(id)
                continue
            }
            claimedIdentities.insert(cloudSnapshot.identityKey)
            let hasCredential = await local.hasCredential(accountId: id, authType: cloudSnapshot.authType, kind: cloudSnapshot.kind)
            await local.insertFromCloud(cloudSnapshot, hasCredential: hasCredential)
            summary.insertedAccounts.append(.init(accountId: id, hasCredential: hasCredential))
        }

        payload.accounts = Array(cloudById.values)
        if payloadChanged {
            savePayload(payload)
        }
        return summary
    }

    /// Pushes one locally-added/-changed account to the cloud immediately,
    /// rather than waiting for the next full `reconcile()` — called right
    /// after a local insert/update. A no-op while sync is toggled off.
    public func pushLocalChange(_ snapshot: CloudAccountSnapshot) async {
        guard isEnabled() else { return }
        // `CloudAccountSnapshot.isDevelopmentAccount`'s doc comment: a
        // dev/test account must never reach the real iCloud KVS payload at
        // all, and this immediate-push path (called right after a local
        // add/edit, `AppEnvironment.pushAccountToCloud`) is the one
        // `reconcile()`'s own up-front filtering doesn't cover — this is
        // its counterpart.
        guard !snapshot.isDevelopmentAccount else { return }
        await acquirePayloadLock()
        defer { releasePayloadLock() }
        var payload = loadPayload()
        payload.tombstones.removeAll { $0.accountId == snapshot.accountId }
        payload.accounts.removeAll { $0.accountId == snapshot.accountId }
        payload.accounts.append(snapshot)
        savePayload(payload)
    }

    /// Records a local deletion as a tombstone immediately, rather than
    /// waiting for the next full `reconcile()` — called right after a
    /// user-initiated `deleteAccount`. Must **not** be called for a
    /// deletion that itself originated from a cloud tombstone
    /// (`reconcile()`'s phase 2 already handles that case without pushing
    /// a redundant new one). A no-op while sync is toggled off.
    public func pushLocalDeletion(accountId: String) async {
        guard isEnabled() else { return }
        await acquirePayloadLock()
        defer { releasePayloadLock() }
        var payload = loadPayload()
        payload.accounts.removeAll { $0.accountId == accountId }
        payload.tombstones.removeAll { $0.accountId == accountId }
        payload.tombstones.append(AccountTombstone(accountId: accountId, deletedAt: now()))
        savePayload(payload)
    }

    private func loadPayload() -> AccountCloudPayload {
        guard let data = store.data(forKey: Self.payloadKey) else { return AccountCloudPayload() }
        return (try? JSONDecoder.accountCloudSync.decode(AccountCloudPayload.self, from: data)) ?? AccountCloudPayload()
    }

    @discardableResult
    private func savePayload(_ payload: AccountCloudPayload) -> Bool {
        guard let data = try? JSONEncoder.accountCloudSync.encode(payload) else { return false }
        guard data.count <= Self.maxPayloadBytes else { return false }
        store.set(data, forKey: Self.payloadKey)
        store.synchronize()
        return true
    }
}

private extension JSONEncoder {
    static let accountCloudSync: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let accountCloudSync: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
