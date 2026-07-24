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
    /// `true` when `reconcile()` short-circuited because iCloud account sync
    /// is toggled off (`AccountCloudSyncEngine.isEnabled`) — every other
    /// field is empty in that case, since nothing was looked at at all.
    public var disabled = false

    public init(
        insertedAccounts: [InsertedAccount] = [],
        updatedAccountIds: [String] = [],
        deletedAccountIds: [String] = [],
        pushedAccountIds: [String] = [],
        disabled: Bool = false
    ) {
        self.insertedAccounts = insertedAccounts
        self.updatedAccountIds = updatedAccountIds
        self.deletedAccountIds = deletedAccountIds
        self.pushedAccountIds = pushedAccountIds
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

        let localSnapshots = await local.allAccountSnapshots()
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
        // has neither a local copy nor a tombstone for is new — insert it.
        for (id, cloudSnapshot) in cloudById where localById[id] == nil && !tombstoneIds.contains(id) {
            let hasCredential = await local.hasCredential(accountId: id, authType: cloudSnapshot.authType)
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
