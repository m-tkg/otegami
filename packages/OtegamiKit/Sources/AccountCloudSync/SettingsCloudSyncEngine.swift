import Foundation
import os

/// What `SettingsCloudSyncEngine.reconcile()` actually did — mirrors
/// `ReconcileSummary`'s role for the account engine, just simpler (this
/// payload has no per-item merge in the account-engine sense, so there's
/// nothing finer-grained than "which direction(s) won" to report).
public enum SettingsReconcileResult: Equatable, Sendable {
    /// This device's local settings had changed since the last time this
    /// device synced, so they were pushed to the cloud. Every changed key
    /// was this device's own.
    case pushed
    /// The cloud payload was newer than this device's own last-synced
    /// baseline, so its values were written into local `UserDefaults`.
    /// Every changed key came from the cloud.
    case pulled
    /// Task #144 (settings.v2 per-key merge): both directions happened in
    /// the same `reconcile()` call — at least one key was pulled from the
    /// cloud (another device changed it more recently) *and* at least one
    /// other key was pushed to the cloud (this device changed a different
    /// key more recently). Neither device's change was discarded.
    case merged
    /// Local settings match this device's last-synced baseline, and that
    /// baseline is at least as new as the cloud's for every key — nothing
    /// to do.
    case inSync
    /// `reconcile()` short-circuited because iCloud settings sync is
    /// toggled off (mirrors `ReconcileSummary.disabled`).
    case disabled
}

/// Owns the `"settings.v2"` iCloud KVS key: the display-settings
/// counterpart to `AccountCloudSyncEngine` (`"accounts.v1"`), fixing the
/// real-device report that a re-installed app resets every UI preference
/// (thread display, etc.) back to its compiled-in default because
/// `UserDefaults` itself doesn't survive an uninstall — see
/// `docs/icloud-sync.md`'s settings-sync section for the full story.
///
/// **Task #144 (settings.v2, per-key merge)**: through `"settings.v1"`, the
/// whole `SettingsCloudPayload` was one flat bag with a single `updatedAt`
/// timestamp, so `reconcile()` only ever had three real outcomes — push,
/// pull, or nothing to do. That had one known design limitation
/// (`SettingsCloudPayload`'s doc comment, `docs/icloud-sync.md`'s old
/// "積み残し (v2 移行)" section): two devices that each changed a *different*
/// setting before either synced again would have whichever push landed last
/// win the *entire* bag, discarding the other device's unrelated change —
/// a real risk once a user runs this app across iPhone/iPad/Mac. `"settings.v2"`
/// (`SettingsCloudPayload.entries: [String: SettingsCloudEntry]`, one
/// `updatedAt` *per key*) removes that limitation: `reconcile()` now merges
/// key-by-key, so independent changes on different devices both survive
/// (`SettingsReconcileResult.merged`).
///
/// The three-way decision from before is still exactly how a device that
/// has **never synced at all** is handled (`merge(cloudPayload:snapshot:)`
/// needs a prior snapshot to diff against — there's nothing per-key to
/// merge before that):
///
/// 1. **This device has never synced settings at all**
///    (`lastSyncedSnapshot() == nil` — true for a fresh install, and
///    critically also true for a *re*-install, since that bookkeeping lives
///    in the very `UserDefaults` storage the reinstall wipes) **and the
///    cloud already has a real payload** (`!cloudPayload.entries.isEmpty`) →
///    pull the whole thing, never push: pushing this device's compiled-in
///    defaults here would silently clobber whatever the user had actually
///    chosen on every other device — exactly the bug this feature exists to
///    prevent.
/// 2. **Never synced locally, and the cloud is also empty** → this is
///    genuinely the first device ever to sync → push local values up with a
///    fresh timestamp for every key.
/// 3. **Everything else** (this device has synced settings before, i.e. a
///    real `snapshot` exists) → `merge(cloudPayload:snapshot:)`: per-key
///    last-writer-wins against that snapshot — see its own doc comment.
///
/// **Task #101** (実機報告「スレッド表示をオフにしても再起動で戻る」): the
/// pre-#144 pull path re-read `local.currentValues()` immediately before
/// writing anything, because a local edit landing during `reconcile()`'s own
/// `await`s (this whole call can itself be triggered by another device's
/// push arriving via `didChangeExternallyNotification` at any moment,
/// including the instant a user taps a settings toggle) used to be invisible
/// to a decision already made against stale data. `merge(cloudPayload:snapshot:)`
/// generalizes that guard: it re-reads `local.currentValues()` itself as its
/// one and only source of "what's local right now" rather than trusting
/// whatever `reconcile()` captured earlier, so there's no stale-decision
/// window left for *any* key. The never-synced pull path (`pull(_:becauseOfReason
/// :observedLocalValues:)`) keeps its own dedicated re-check for the same
/// reason it always had one — see that method's doc comment.
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
    /// — a flat bag of ~20 short bool/string entries (now each carrying its
    /// own timestamp too) is still nowhere near this, but the guard exists
    /// so a future runaway key can't silently wedge every other KVS key this
    /// app uses by pushing the *total* store past its real 1MB ceiling.
    public static let maxPayloadBytes = 60_000

    private static let payloadKey = "settings.v2"
    /// Task #144: the pre-#144 KVS key, read-only from here on —
    /// `loadPayload()` falls back to it only when `"settings.v2"` doesn't
    /// exist yet on this KVS store, so a user upgrading their devices to
    /// this version at different times doesn't have an unmigrated device
    /// treat the other's real settings as "cloud has nothing" and push
    /// stale defaults over them. Never written to (`savePayload(_:)` only
    /// ever targets `payloadKey`).
    private static let legacyPayloadKeyV1 = "settings.v1"

    /// Task #101 (実機報告「スレッド表示をオフにしても再起動で戻る」): one
    /// `Logger` line per `reconcile()` call stating the outcome (push/pull/
    /// merged/no-op/disabled), why, which keys disagree between local and
    /// cloud, and every timestamp involved — a real-device `log stream`
    /// capture is otherwise the only way to tell "this device pushed its
    /// change" from "this device pulled over it" after the fact, since both
    /// look identical from the UI (the toggle just silently reverts). See
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

    /// Full reconcile: see this type's doc comment for the decision tree.
    /// Safe (and cheap — a no-op write when nothing changed) to call
    /// repeatedly; this is the app-launch entry point, the
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

        guard let snapshot else {
            if !cloudPayload.entries.isEmpty {
                return await pull(
                    cloudPayload, becauseOfReason: "never synced on this device (fresh install/reinstall); cloud already has a payload",
                    observedLocalValues: localValues
                )
            }
            return await push(
                localValues: localValues, cloudPayload: cloudPayload,
                reason: "first device ever to sync (cloud is also empty)"
            )
        }

        return await merge(cloudPayload: cloudPayload, snapshot: snapshot)
    }

    /// Task #144: the steady-state path once this device has synced settings
    /// before (`snapshot` is a real, non-nil payload) — a per-key
    /// last-writer-wins merge against `cloudPayload`, replacing the pre-#144
    /// whole-bag "local unchanged & cloud newer -> pull, else push" branch.
    ///
    /// For each of this device's currently-allowlisted keys (`freshLocalValues`,
    /// re-read here rather than trusting anything `reconcile()` captured
    /// earlier — see this type's doc comment on why that closes the Task
    /// #101 race generally instead of needing a dedicated re-check):
    /// - If the live value still matches `snapshot`'s entry for this key,
    ///   nothing changed here since the last sync — its candidate timestamp
    ///   is whatever this device last agreed to for it (`snapshot`'s own
    ///   `updatedAt` for that key, or `.distantPast` if this key is new to
    ///   this device's snapshot).
    /// - Otherwise, the live value disagrees with the snapshot — a genuine
    ///   local change since the last sync, whenever it actually happened.
    ///   There is no per-write hook to know exactly when
    ///   (`AppSettingsCloudDirectory`'s doc comment), so it's stamped `now()`
    ///   ("changed as of this reconcile" is the closest available truth).
    /// - Whichever of that local candidate and `cloudPayload`'s entry for
    ///   this key (if any) has the newer `updatedAt` wins; a tie keeps the
    ///   local candidate (arbitrary but stable — avoids oscillating on
    ///   perfectly-simultaneous timestamps, which only really arises in
    ///   tests).
    ///
    /// The merged bag is applied locally (only for keys whose winner differs
    /// from the live value — a real pull) and pushed to the cloud (only if
    /// the merged bag actually differs from what's there — a real push);
    /// either, both, or neither can happen in one call, which is exactly
    /// what `SettingsReconcileResult.merged` exists to report when both did.
    private func merge(cloudPayload: SettingsCloudPayload, snapshot: SettingsCloudPayload) async -> SettingsReconcileResult {
        let freshLocalValues = await local.currentValues()
        let mergeNow = now()

        var mergedEntries: [String: SettingsCloudEntry] = [:]
        var appliedKeys: [String] = []
        var pushNeeded = false

        for (key, localValue) in freshLocalValues {
            let snapshotEntry = snapshot.entries[key]
            let cloudEntry = cloudPayload.entries[key]

            let changedSinceSnapshot = localValue != snapshotEntry?.value
            let localCandidate = SettingsCloudEntry(
                value: localValue,
                updatedAt: changedSinceSnapshot ? mergeNow : (snapshotEntry?.updatedAt ?? .distantPast)
            )

            let winner: SettingsCloudEntry
            if let cloudEntry, cloudEntry.updatedAt > localCandidate.updatedAt {
                winner = cloudEntry
            } else {
                winner = localCandidate
            }
            mergedEntries[key] = winner

            if winner.value != localValue {
                appliedKeys.append(key)
            }
            if cloudEntry?.value != winner.value || cloudEntry?.updatedAt != winner.updatedAt {
                pushNeeded = true
            }
        }

        // Task #186: preserve any cloud entry this device has no opinion on
        // at all — i.e. a key `freshLocalValues` never produced. Before
        // Task #186 this branch was unreachable in practice: every synced
        // key came from `AppSettingsCloudDirectory`'s *static* allowlist,
        // which every device running the same app version evaluates
        // identically (always present, real value or compiled-in default),
        // so `freshLocalValues` and `cloudPayload.entries` always shared
        // the exact same key set. Task #186 adds genuinely *dynamic* keys
        // (`LastSignatureSettingsStore`'s per-account
        // `"signature.lastSelectedId.<accountId>"` — one device may simply
        // never have recorded a selection for an account another device
        // has) where that invariant no longer holds. Without this loop, the
        // pre-#186 code below (`SettingsCloudPayload(entries: mergedEntries)`)
        // would silently *delete* any such foreign key the next time this
        // device pushes for an unrelated reason — this device's `apply(_:)`
        // already safely ignores a key it doesn't recognize
        // (`AppSettingsCloudDirectory.apply(_:)`'s own guard), so simply
        // echoing the cloud's entry back unchanged is always safe: it never
        // gets written to this device's `UserDefaults`, and it isn't
        // dropped for every other device that *does* care about it either.
        for (key, cloudEntry) in cloudPayload.entries where mergedEntries[key] == nil {
            mergedEntries[key] = cloudEntry
        }

        let mergedPayload = SettingsCloudPayload(entries: mergedEntries)

        if !appliedKeys.isEmpty {
            await local.apply(mergedPayload)
        }
        if pushNeeded, !savePayload(mergedPayload) {
            // Encoding/size guard tripped (`savePayload(_:)`'s doc comment)
            // — nothing reached the cloud this cycle, but whatever was
            // decided locally above still happened, so this device's
            // baseline below still reflects it (matches the pre-#144
            // push failure path's "treat as a no-op this cycle" choice).
            pushNeeded = false
        }

        let result: SettingsReconcileResult
        switch (appliedKeys.isEmpty, pushNeeded) {
        case (true, false): result = .inSync
        case (true, true): result = .pushed
        case (false, false): result = .pulled
        case (false, true): result = .merged
        }

        if result != .inSync {
            await local.saveSyncedSnapshot(mergedPayload)
        }

        log(
            result,
            reason: result == .inSync
                ? "local matches last-synced snapshot; cloud is not newer for any key"
                : "per-key merge (keys applied locally: [\(appliedKeys.sorted().joined(separator: ","))])",
            local: freshLocalValues, cloud: cloudPayload, snapshot: snapshot
        )
        return result
    }

    /// The never-synced-on-this-device pull path — re-reads
    /// `local.currentValues()` immediately before actually overwriting
    /// anything, and falls back to pushing the fresher value if it disagrees
    /// with what was observed when `reconcile()` decided to pull (Task #101;
    /// see this type's doc comment). There is no prior `snapshot` to merge
    /// against here (by definition — this device has never synced), so this
    /// stays a whole-payload pull, matching the pre-#144 shape exactly.
    private func pull(
        _ cloudPayload: SettingsCloudPayload, becauseOfReason reason: String,
        observedLocalValues: [String: SettingsCloudValue]
    ) async -> SettingsReconcileResult {
        let freshLocalValues = await local.currentValues()
        guard freshLocalValues == observedLocalValues else {
            return await push(
                localValues: freshLocalValues, cloudPayload: cloudPayload,
                reason: "local changed again while deciding to pull (\(reason)); a fresh local edit wins over a stale pull decision"
            )
        }
        log(.pulled, reason: reason, local: observedLocalValues, cloud: cloudPayload, snapshot: nil)
        await local.apply(cloudPayload)
        await local.saveSyncedSnapshot(cloudPayload)
        return .pulled
    }

    /// The first-device-ever-to-sync whole-payload push (and `pull(_:
    /// becauseOfReason:observedLocalValues:)`'s own race-fallback) — every
    /// key gets the same fresh `now()` timestamp, exactly the pre-#144
    /// shape. The steady-state per-key push path lives inside
    /// `merge(cloudPayload:snapshot:)` instead.
    private func push(
        localValues: [String: SettingsCloudValue], cloudPayload: SettingsCloudPayload, reason: String
    ) async -> SettingsReconcileResult {
        let newPayload = SettingsCloudPayload(values: localValues, updatedAt: now())
        guard savePayload(newPayload) else {
            log(.inSync, reason: "push failed (payload encoding/size guard) — treating as a no-op this cycle", local: localValues, cloud: cloudPayload, snapshot: nil)
            return .inSync
        }
        log(.pushed, reason: reason, local: localValues, cloud: cloudPayload, snapshot: nil)
        await local.saveSyncedSnapshot(newPayload)
        return .pushed
    }

    /// Task #144: tries the current `"settings.v2"` KVS key first; only
    /// when that key doesn't exist at all on this KVS store does it fall
    /// back to reading the legacy `"settings.v1"` key (see `payloadKey`'s
    /// doc comment for why this matters during a staggered multi-device
    /// upgrade). Both are decoded through the same `SettingsCloudPayload`
    /// initializer, which already reads either wire shape — so the v1
    /// fallback needs no separate parsing logic here.
    private func loadPayload() -> SettingsCloudPayload {
        if let data = store.data(forKey: Self.payloadKey),
           let payload = try? JSONDecoder.settingsCloudSync.decode(SettingsCloudPayload.self, from: data) {
            return payload
        }
        guard let legacyData = store.data(forKey: Self.legacyPayloadKeyV1) else { return SettingsCloudPayload() }
        return (try? JSONDecoder.settingsCloudSync.decode(SettingsCloudPayload.self, from: legacyData)) ?? SettingsCloudPayload()
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
