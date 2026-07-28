import Foundation
import os

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
/// **Task #101** (実機報告「スレッド表示をオフにしても再起動で戻る」):
/// branches 1/2 above both decide to pull based on `localValues`/`snapshot`
/// captured *before* their own `await`s — a local edit landing during that
/// window (this whole call can itself be triggered by another device's push
/// arriving via `didChangeExternallyNotification` at any moment, including
/// the instant a user taps a settings toggle) used to be invisible to that
/// decision and got silently clobbered by `apply()`. `pull(_:becauseOfReason
/// :observedLocalValues:snapshot:)` now re-reads `local.currentValues()`
/// immediately before writing anything and falls back to pushing the fresher
/// value if it disagrees with what was observed — see that method's doc
/// comment, and `docs/icloud-sync.md`'s Task #101 section for the full
/// writeup and the OSLog invocation that surfaces this on a real device.
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

    /// Task #101 (実機報告「スレッド表示をオフにしても再起動で戻る」): one
    /// `Logger` line per `reconcile()` call stating the outcome (push/pull/
    /// no-op/disabled), why, which keys disagree between local and cloud,
    /// and every timestamp involved — a real-device `log stream` capture is
    /// otherwise the only way to tell "this device pushed its change" from
    /// "this device pulled over it" after the fact, since both look
    /// identical from the UI (the toggle just silently reverts). See
    /// `docs/icloud-sync.md`'s Task #101 section for the `log stream`
    /// invocation this is meant to be read with.
    private static let logger = Logger(subsystem: "com.mtkg.otegami", category: "SettingsCloudSync")

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
        guard isEnabled() else {
            Self.logger.debug("reconcile -> disabled (iCloud settings sync is off)")
            return .disabled
        }
        await acquirePayloadLock()
        defer { releasePayloadLock() }

        let cloudPayload = loadPayload()
        let localValues = await local.currentValues()
        let snapshot = await local.lastSyncedSnapshot()

        if let snapshot, snapshot.values == localValues {
            guard cloudPayload.updatedAt > snapshot.updatedAt else {
                log(.inSync, reason: "local matches last-synced snapshot; cloud is not newer", local: localValues, cloud: cloudPayload, snapshot: snapshot)
                return .inSync
            }
            return await pull(
                cloudPayload, becauseOfReason: "local unchanged since last sync; cloud has a newer payload",
                observedLocalValues: localValues, snapshot: snapshot
            )
        }

        if snapshot == nil, !cloudPayload.values.isEmpty {
            return await pull(
                cloudPayload, becauseOfReason: "never synced on this device (fresh install/reinstall); cloud already has a payload",
                observedLocalValues: localValues, snapshot: snapshot
            )
        }

        return await push(
            localValues: localValues, cloudPayload: cloudPayload, snapshot: snapshot,
            reason: snapshot == nil ? "first device ever to sync (cloud is also empty)" : "local changed since last sync"
        )
    }

    /// Both places `reconcile()` above decided a pull is warranted funnel
    /// through here, which re-reads `local.currentValues()` one more time
    /// immediately before actually overwriting anything. This closes a real
    /// race (Task #101, the exact real-device repro of "toggle a display
    /// setting off, it reverts on the next restart"): `reconcile()`'s two
    /// `await`s above (`local.currentValues()`, `local.lastSyncedSnapshot()`)
    /// are genuine suspension points, and this whole call can itself be
    /// triggered by another device's push landing via
    /// `didChangeExternallyNotification` at literally any moment — including
    /// the instant the user taps a settings toggle on *this* device. Without
    /// this re-check, a local edit that lands in that window is invisible to
    /// the branch logic above (it already captured `observedLocalValues`
    /// before the edit happened) and `apply(cloudPayload)` would silently
    /// overwrite it. A local edit discovered here always outranks a pull
    /// decision that was made against now-stale data, so this falls through
    /// to `push(_:)` instead of applying the pull.
    private func pull(
        _ cloudPayload: SettingsCloudPayload, becauseOfReason reason: String,
        observedLocalValues: [String: SettingsCloudValue], snapshot: SettingsCloudPayload?
    ) async -> SettingsReconcileResult {
        let freshLocalValues = await local.currentValues()
        guard freshLocalValues == observedLocalValues else {
            return await push(
                localValues: freshLocalValues, cloudPayload: cloudPayload, snapshot: snapshot,
                reason: "local changed again while deciding to pull (\(reason)); a fresh local edit wins over a stale pull decision"
            )
        }
        log(.pulled, reason: reason, local: observedLocalValues, cloud: cloudPayload, snapshot: snapshot)
        await local.apply(cloudPayload)
        await local.saveSyncedSnapshot(cloudPayload)
        return .pulled
    }

    private func push(
        localValues: [String: SettingsCloudValue], cloudPayload: SettingsCloudPayload,
        snapshot: SettingsCloudPayload?, reason: String
    ) async -> SettingsReconcileResult {
        let newPayload = SettingsCloudPayload(values: localValues, updatedAt: now())
        guard savePayload(newPayload) else {
            log(.inSync, reason: "push failed (payload encoding/size guard) — treating as a no-op this cycle", local: localValues, cloud: cloudPayload, snapshot: snapshot)
            return .inSync
        }
        log(.pushed, reason: reason, local: localValues, cloud: cloudPayload, snapshot: snapshot)
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

    /// One `Logger` line per `reconcile()` outcome — see `logger`'s doc
    /// comment. `diffKeys` is every allowlisted key where `local` and
    /// `cloud.values` currently disagree (regardless of which one this call
    /// picked), which is usually more useful on a real device than the full
    /// payload: it immediately shows *which* setting is in contention
    /// without needing to decode both payloads by hand.
    private func log(
        _ result: SettingsReconcileResult, reason: String,
        local: [String: SettingsCloudValue], cloud: SettingsCloudPayload, snapshot: SettingsCloudPayload?
    ) {
        let diffKeys = Self.diffKeys(local, cloud.values).sorted().joined(separator: ",")
        Self.logger.info(
            "reconcile -> \(String(describing: result), privacy: .public): \(reason, privacy: .public) | diffKeys=[\(diffKeys, privacy: .public)] | snapshot.updatedAt=\(snapshot?.updatedAt.description ?? "nil", privacy: .public) | cloud.updatedAt=\(cloud.updatedAt.description, privacy: .public)"
        )
    }

    private static func diffKeys(_ a: [String: SettingsCloudValue], _ b: [String: SettingsCloudValue]) -> [String] {
        var keys = Set<String>()
        for (key, value) in a where b[key] != value { keys.insert(key) }
        for (key, value) in b where a[key] != value { keys.insert(key) }
        return Array(keys)
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
