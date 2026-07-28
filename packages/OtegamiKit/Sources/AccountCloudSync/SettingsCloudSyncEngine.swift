import Foundation

/// What `SettingsCloudSyncEngine.reconcile()` actually did — mirrors
/// `ReconcileSummary`'s role for the account engine, just simpler (this
/// payload has no per-item merge, so there's nothing finer-grained than
/// "which single direction won" to report).
public enum SettingsReconcileResult: Equatable, Sendable {
    /// This device's local settings had changed since the last time this
    /// device synced, so they were pushed to the cloud.
    case pushed
    /// The cloud payload was newer than this device's own last-synced
    /// baseline, so its values were written into local `UserDefaults`.
    case pulled
    /// Local settings match this device's last-synced baseline, and that
    /// baseline is at least as new as the cloud's — nothing to do.
    case inSync
    /// `reconcile()` short-circuited because iCloud settings sync is
    /// toggled off (mirrors `ReconcileSummary.disabled`).
    case disabled
}

/// Owns the `"settings.v1"` iCloud KVS key: the display-settings
/// counterpart to `AccountCloudSyncEngine` (`"accounts.v1"`), fixing the
/// real-device report that a re-installed app resets every UI preference
/// (thread display, etc.) back to its compiled-in default because
/// `UserDefaults` itself doesn't survive an uninstall — see
/// `docs/icloud-sync.md`'s settings-sync section for the full story.
///
/// Unlike the account engine, there is no per-item merge here: the whole
/// `SettingsCloudPayload` is one flat bag with a single `updatedAt`
/// timestamp, so `reconcile()` only ever has three real outcomes — push,
/// pull, or nothing to do (`SettingsReconcileResult`). The three-way
/// decision:
///
/// 1. **Local unchanged since this device's last sync** (`currentValues()`
///    still equals `lastSyncedSnapshot()`'s `values`) **and the cloud has
///    something newer** (`cloudPayload.updatedAt > snapshot.updatedAt`) →
///    pull: another device pushed since this one last synced.
/// 2. **This device has never synced settings at all**
///    (`lastSyncedSnapshot() == nil` — true for a fresh install, and
///    critically also true for a *re*-install, since that bookkeeping lives
///    in the very `UserDefaults` storage the reinstall wipes) **and the
///    cloud already has a real payload** (`!cloudPayload.values.isEmpty`) →
///    pull, never push: pushing this device's compiled-in defaults here
///    would silently clobber whatever the user had actually chosen on
///    every other device — exactly the bug this feature exists to prevent.
/// 3. **Everything else** — local values differ from this device's last
///    synced baseline (a real local change since last sync), or this is
///    genuinely the first device ever to sync (never synced locally *and*
///    the cloud is still empty) → push local values up with a fresh
///    timestamp.
///
/// Two independent local changes racing between two devices' reconciles
/// isn't reconciled any more precisely than "whichever push lands last, in
/// wall-clock terms, wins the whole bag" — acceptable per the plan's own
/// simplification (`SettingsCloudPayload`'s doc comment) for independent UI
/// preferences with no cross-field invariants to protect.
///
/// An `actor` for the same reason as `AccountCloudSyncEngine`: every
/// operation here is either pure data-juggling or awaits onto
/// `LocalSettingsDirectory`/`UbiquitousStoring`, nothing UI-related. Guards
/// its own "load payload, decide, maybe write it back" critical section
/// with the same actor-reentrancy mutex `AccountCloudSyncEngine` uses (see
/// that type's doc comment for the concrete race it closes) — real
/// suspension across `local`'s `await` points is unlikely in production
/// (`UserDefaults` is effectively synchronous), but the protocol allows a
/// fake to suspend there in tests, and the fix is cheap enough not to skip.
public actor SettingsCloudSyncEngine {
    /// Mirrors `AccountCloudSyncEngine.maxPayloadBytes`'s reasoning exactly
    /// — a flat bag of ~20 short bool/string entries is a few hundred bytes
    /// at most, nowhere near this, but the guard still exists so a future
    /// runaway key (e.g. an unbounded free-text value accidentally added to
    /// the allowlist) can't silently wedge every other KVS key this app
    /// uses by pushing the *total* store past its real 1MB ceiling.
    public static let maxPayloadBytes = 60_000

    private static let payloadKey = "settings.v1"

    private let store: any UbiquitousStoring
    private let local: any LocalSettingsDirectory
    private let now: @Sendable () -> Date
    private let isEnabled: @Sendable () -> Bool

    /// Same shape (and same reasoning) as `AccountCloudSyncEngine`'s
    /// payload lock — see that property's doc comment for the concrete
    /// reentrancy hazard this closes.
    private var isPayloadLocked = false
    private var payloadLockWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquirePayloadLock() async {
        if isPayloadLocked {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                payloadLockWaiters.append(continuation)
            }
            return
        }
        isPayloadLocked = true
    }

    private func releasePayloadLock() {
        guard isPayloadLocked else { return }
        if payloadLockWaiters.isEmpty {
            isPayloadLocked = false
        } else {
            payloadLockWaiters.removeFirst().resume()
        }
    }

    public init(
        store: any UbiquitousStoring,
        local: any LocalSettingsDirectory,
        now: @escaping @Sendable () -> Date = Date.init,
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.store = store
        self.local = local
        self.now = now
        self.isEnabled = isEnabled
    }

    /// Full reconcile: see this type's doc comment for the three-way
    /// decision. Safe (and cheap — a no-op write when nothing changed) to
    /// call repeatedly; this is the app-launch entry point, the
    /// `didChangeExternallyNotification` entry point, and the
    /// foreground/background scene-phase entry point (there is no per-write
    /// hook at every `*SettingsStore` call site — see `AppSettingsCloudDirectory`'s
    /// doc comment for why a periodic/transition-triggered diff was chosen
    /// over that).
    @discardableResult
    public func reconcile() async -> SettingsReconcileResult {
        guard isEnabled() else { return .disabled }
        await acquirePayloadLock()
        defer { releasePayloadLock() }

        let cloudPayload = loadPayload()
        let localValues = await local.currentValues()
        let snapshot = await local.lastSyncedSnapshot()

        if let snapshot, snapshot.values == localValues {
            guard cloudPayload.updatedAt > snapshot.updatedAt else { return .inSync }
            await local.apply(cloudPayload)
            await local.saveSyncedSnapshot(cloudPayload)
            return .pulled
        }

        if snapshot == nil, !cloudPayload.values.isEmpty {
            await local.apply(cloudPayload)
            await local.saveSyncedSnapshot(cloudPayload)
            return .pulled
        }

        let newPayload = SettingsCloudPayload(values: localValues, updatedAt: now())
        guard savePayload(newPayload) else { return .inSync }
        await local.saveSyncedSnapshot(newPayload)
        return .pushed
    }

    private func loadPayload() -> SettingsCloudPayload {
        guard let data = store.data(forKey: Self.payloadKey) else { return SettingsCloudPayload() }
        return (try? JSONDecoder.settingsCloudSync.decode(SettingsCloudPayload.self, from: data)) ?? SettingsCloudPayload()
    }

    @discardableResult
    private func savePayload(_ payload: SettingsCloudPayload) -> Bool {
        guard let data = try? JSONEncoder.settingsCloudSync.encode(payload) else { return false }
        guard data.count <= Self.maxPayloadBytes else { return false }
        store.set(data, forKey: Self.payloadKey)
        store.synchronize()
        return true
    }
}

private extension JSONEncoder {
    static let settingsCloudSync: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let settingsCloudSync: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
