import Foundation
import Testing
@testable import AccountCloudSync

@Suite("SettingsCloudSyncEngine")
struct SettingsCloudSyncEngineTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = Date(timeIntervalSince1970: 1_700_000_100)

    private func makeEngine(
        store: FakeUbiquitousStore = FakeUbiquitousStore(),
        local: FakeLocalSettingsDirectory = FakeLocalSettingsDirectory(),
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_100) },
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) -> SettingsCloudSyncEngine {
        SettingsCloudSyncEngine(store: store, local: local, now: now, isEnabled: isEnabled)
    }

    // MARK: - First run (no prior sync on this device)

    @Test
    func firstDeviceEverPushesItsCurrentValuesAsTheInitialPayload() async {
        let store = FakeUbiquitousStore()
        let local = FakeLocalSettingsDirectory()
        local.values = ["listDisplay.threading": .bool(false)]
        let engine = makeEngine(store: store, local: local, now: { self.later })

        let result = await engine.reconcile()

        #expect(result == .pushed)
        #expect(store.currentPayload(key: "settings.v2")?.values == ["listDisplay.threading": .bool(false)])
        #expect(store.currentPayload(key: "settings.v2")?.updatedAt == later)
        #expect(await local.lastSyncedSnapshot()?.values == ["listDisplay.threading": .bool(false)])
    }

    /// The exact reinstall bug this feature exists to fix: this device has
    /// never synced settings before (no `lastSyncedSnapshot` — the reported
    /// scenario is that a reinstall wiped it, but "brand-new device" looks
    /// identical from the engine's point of view), and the cloud already
    /// carries a real payload from another device. Pushing this device's
    /// compiled-in defaults here would silently clobber the real value.
    @Test
    func neverSyncedDeviceWithAnExistingCloudPayloadPullsRatherThanPushingDefaults() async {
        let store = FakeUbiquitousStore()
        store.seed(SettingsCloudPayload(values: ["listDisplay.threading": .bool(false)], updatedAt: epoch), key: "settings.v2")
        let local = FakeLocalSettingsDirectory()
        // This device's in-memory defaults disagree with the cloud —
        // exactly what a freshly wiped `UserDefaults` looks like.
        local.values = ["listDisplay.threading": .bool(true)]
        let engine = makeEngine(store: store, local: local)

        let result = await engine.reconcile()

        #expect(result == .pulled)
        #expect(local.appliedPayloads.map(\.values) == [["listDisplay.threading": .bool(false)]])
        // The cloud payload was not overwritten with this device's defaults.
        #expect(store.currentPayload(key: "settings.v2")?.updatedAt == epoch)
    }

    // MARK: - Steady state

    @Test
    func inSyncWhenLocalMatchesTheLastSyncedSnapshotAndTheCloudIsNotNewer() async {
        let store = FakeUbiquitousStore()
        let snapshot = SettingsCloudPayload(values: ["listDisplay.threading": .bool(true)], updatedAt: epoch)
        store.seed(snapshot, key: "settings.v2")
        let local = FakeLocalSettingsDirectory()
        local.values = snapshot.values
        local.snapshot = snapshot
        let engine = makeEngine(store: store, local: local)

        let result = await engine.reconcile()

        #expect(result == .inSync)
        #expect(store.setCallCount == 0)
        #expect(local.appliedPayloads.isEmpty)
    }

    @Test
    func localChangeSinceLastSyncIsPushedEvenWhenACloudPayloadAlreadyExists() async {
        let store = FakeUbiquitousStore()
        let oldSnapshot = SettingsCloudPayload(values: ["listDisplay.threading": .bool(true)], updatedAt: epoch)
        store.seed(oldSnapshot, key: "settings.v2")
        let local = FakeLocalSettingsDirectory()
        local.snapshot = oldSnapshot
        // The user flipped the toggle on this device since the last sync.
        local.values = ["listDisplay.threading": .bool(false)]
        let engine = makeEngine(store: store, local: local, now: { self.later })

        let result = await engine.reconcile()

        #expect(result == .pushed)
        #expect(store.currentPayload(key: "settings.v2")?.values == ["listDisplay.threading": .bool(false)])
        #expect(store.currentPayload(key: "settings.v2")?.updatedAt == later)
        #expect(await local.lastSyncedSnapshot()?.updatedAt == later)
    }

    @Test
    func cloudNewerThanThisDevicesLastSyncedSnapshotIsPulledDown() async {
        let store = FakeUbiquitousStore()
        let cloudPayload = SettingsCloudPayload(values: ["listDisplay.threading": .bool(false)], updatedAt: later)
        store.seed(cloudPayload, key: "settings.v2")
        let local = FakeLocalSettingsDirectory()
        // This device's own last-synced baseline is older and unchanged
        // locally since — another device pushed a newer value meanwhile.
        local.snapshot = SettingsCloudPayload(values: ["listDisplay.threading": .bool(true)], updatedAt: epoch)
        local.values = ["listDisplay.threading": .bool(true)]
        let engine = makeEngine(store: store, local: local)

        let result = await engine.reconcile()

        #expect(result == .pulled)
        #expect(local.appliedPayloads.map(\.values) == [["listDisplay.threading": .bool(false)]])
        #expect(await local.lastSyncedSnapshot()?.updatedAt == later)
    }

    // MARK: - Task #101 (実機報告「スレッド表示をオフにしても再起動で戻る」)

    /// The literal real-device repro, reduced to a deterministic race: a
    /// pull decision was already made (this device's local values matched
    /// its last-synced snapshot, and the cloud had a genuinely newer
    /// payload from another device) by the time a local edit — a UI toggle
    /// — lands. Before the Task #101 fix, `reconcile()` had already
    /// captured `localValues` *before* this window and would blindly
    /// `apply(cloudPayload)`, silently reverting the toggle the instant the
    /// pull finished; this is exactly what made the bug look like "turn a
    /// setting off, restart, it's back on" with no user-visible cause. This
    /// test pauses `reconcile()` at `lastSyncedSnapshot()` — the point right
    /// after `localValues` was captured but before the pull is carried out
    /// — lands the concurrent write there, and asserts the fresh local edit
    /// wins: it gets pushed, not discarded by the pull.
    @Test
    func concurrentLocalChangeDuringAPullDecisionIsNotDiscarded() async {
        let store = FakeUbiquitousStore()
        let newerCloudPayload = SettingsCloudPayload(values: ["listDisplay.threading": .bool(true)], updatedAt: later)
        store.seed(newerCloudPayload, key: "settings.v2")
        let local = FakeLocalSettingsDirectory()
        // This device's local value still matches its last-synced snapshot
        // right now — the precondition for the "cloud is newer, pull it"
        // branch to even fire.
        local.snapshot = SettingsCloudPayload(values: ["listDisplay.threading": .bool(true)], updatedAt: epoch)
        local.values = ["listDisplay.threading": .bool(true)]

        let reachedPauseGate = AsyncGate()
        let releaseGate = AsyncGate()
        local.onLastSyncedSnapshot = { [weak local] in
            // Only the first call should pause — `pull(_:...)`'s own
            // re-check reads `currentValues()`, not `lastSyncedSnapshot()`
            // again, so in practice this only ever fires once per
            // `reconcile()` call, but clearing it defensively keeps this
            // test's intent explicit rather than relying on that.
            local?.onLastSyncedSnapshot = nil
            await reachedPauseGate.open()
            await releaseGate.wait()
        }

        let muchLater = Date(timeIntervalSince1970: 1_700_000_200)
        let engine = makeEngine(store: store, local: local, now: { muchLater })

        let reconcileTask = Task { await engine.reconcile() }
        // Wait until reconcile() has captured `localValues` and is
        // genuinely suspended right before deciding — not a fixed sleep, so
        // this half of the sequencing is exact.
        await reachedPauseGate.wait()

        // The user toggles the setting off on this device while the paused
        // reconcile() is still mid-decision.
        local.values = ["listDisplay.threading": .bool(false)]

        await releaseGate.open()
        let result = await reconcileTask.value

        #expect(result == .pushed, "a local edit discovered during a pull decision must win, not get silently overwritten by the pull")
        #expect(local.values == ["listDisplay.threading": .bool(false)], "the toggle must still read off after reconcile() finishes")
        #expect(local.appliedPayloads.isEmpty, "apply(_:) must never have been called — the pull was aborted, not carried out")
        #expect(store.currentPayload(key: "settings.v2")?.values == ["listDisplay.threading": .bool(false)])
        #expect(store.currentPayload(key: "settings.v2")?.updatedAt == muchLater)
        #expect(await local.lastSyncedSnapshot()?.values == ["listDisplay.threading": .bool(false)])
    }

    /// Task #101 item 4: two devices, each reconciling in turn, converge on
    /// whichever change actually happened last in wall-clock terms — the
    /// documented "whichever push lands last wins the whole bag" tradeoff
    /// (`SettingsCloudSyncEngine`'s own doc comment) still has to actually
    /// hold end-to-end once both devices get a chance to reconcile again,
    /// not just in a single `reconcile()` call.
    @Test
    func twoDevicePingPongConvergesOnTheNewestValue() async {
        let store = FakeUbiquitousStore()
        let key = "listDisplay.threading"

        // Device A: the very first device to ever sync this feature —
        // pushes its (default, on) value as the initial payload.
        let localA = FakeLocalSettingsDirectory()
        localA.values = [key: .bool(true)]
        let engineA = makeEngine(store: store, local: localA, now: { self.epoch })
        let firstResult = await engineA.reconcile()
        #expect(firstResult == .pushed)

        // Device B: never synced before either, cloud already has A's
        // payload — pulls it rather than pushing its own (possibly
        // different) local defaults.
        let localB = FakeLocalSettingsDirectory()
        localB.values = [key: .bool(false)]
        let engineB = makeEngine(store: store, local: localB, now: { self.later })
        let secondResult = await engineB.reconcile()
        #expect(secondResult == .pulled)
        #expect(localB.values == [key: .bool(true)])

        // The user turns threading off on device B; B reconciles again and
        // pushes it.
        localB.values = [key: .bool(false)]
        let thirdResult = await engineB.reconcile()
        #expect(thirdResult == .pushed)

        // Device A never touched this setting locally in the meantime — its
        // next reconcile must pick up B's newer push rather than re-push its
        // own now-stale "on".
        let fourthResult = await engineA.reconcile()
        #expect(fourthResult == .pulled)
        #expect(localA.values == [key: .bool(false)], "device A must converge on device B's newer off value")
        #expect(localB.values == [key: .bool(false)], "device B must still show its own off value")
        #expect(store.currentPayload(key: "settings.v2")?.values == [key: .bool(false)])
        #expect(store.currentPayload(key: "settings.v2")?.updatedAt == later)
    }

    // MARK: - Task #144 (settings.v2: per-key merge, v1 read compat)

    /// A device that's never synced under `"settings.v2"` (this app's every
    /// existing install, the moment it first launches the code carrying this
    /// migration) must not treat a pre-#144 `"settings.v1"` payload another
    /// device already wrote as "cloud has nothing" — that would silently
    /// push this device's compiled-in defaults over real data, the exact
    /// #89 bug this whole feature exists to prevent, reintroduced by the
    /// migration itself if `loadPayload()` didn't fall back to the old key.
    /// The literal pre-#144 wire shape (a flat `values` bag plus one
    /// whole-payload `updatedAt`, no `entries` key at all) — encoded by hand
    /// here (rather than via `SettingsCloudPayload` itself, which as of
    /// #144 only ever *encodes* the v2 shape) so this test genuinely
    /// exercises `SettingsCloudPayload.init(from:)`'s v1-compat decode
    /// branch, not just the KVS-key fallback.
    private struct LegacyV1Payload: Codable {
        var values: [String: SettingsCloudValue]
        var updatedAt: Date
    }

    @Test
    func neverSyncedUnderV2FallsBackToReadingTheLegacyV1Payload() async {
        let store = FakeUbiquitousStore()
        // Only the legacy key has anything, in the literal legacy shape —
        // simulates every device this user owns still running pre-#144 code.
        let legacy = LegacyV1Payload(values: ["listDisplay.threading": .bool(false)], updatedAt: epoch)
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        store.set(try! legacyEncoder.encode(legacy), forKey: "settings.v1")
        let local = FakeLocalSettingsDirectory()
        local.values = ["listDisplay.threading": .bool(true)]
        let engine = makeEngine(store: store, local: local)

        let result = await engine.reconcile()

        #expect(result == .pulled)
        #expect(local.appliedPayloads.map(\.values) == [["listDisplay.threading": .bool(false)]])
        // A pure pull never re-uploads what it just pulled (same as the
        // pre-#144 pull path) — the KVS store has no `"settings.v2"` entry
        // yet at this point, only this device's own local bookkeeping does.
        #expect(await local.lastSyncedSnapshot()?.values == ["listDisplay.threading": .bool(false)])
        let noPushYet: SettingsCloudPayload? = store.currentPayload(key: "settings.v2")
        #expect(noPushYet == nil)
        #expect(store.currentPayload(key: "settings.v1")?.updatedAt == epoch, "the legacy payload itself is read-only — never overwritten")

        // The device is fully migrated from here on: the next time it has
        // something of its own to reconcile (a local change), it both reads
        // and writes exclusively through `"settings.v2"` — this is the
        // moment the shared KVS store itself actually gains a v2 payload.
        local.values = ["listDisplay.threading": .bool(false), "listDisplay.unreadOnly": .bool(true)]
        let secondResult = await engine.reconcile()
        #expect(secondResult == .pushed)
        let migrated: SettingsCloudPayload? = store.currentPayload(key: "settings.v2")
        #expect(migrated?.values == ["listDisplay.threading": .bool(false), "listDisplay.unreadOnly": .bool(true)])
    }

    /// The exact known limitation `SettingsCloudPayload`'s doc comment
    /// documents as settings.v2's reason to exist: two devices each change a
    /// *different* key before either syncs again. The pre-#144 whole-bag
    /// design would have whichever push happens to land last in wall-clock
    /// terms win the entire bag, silently discarding the other device's
    /// change. The per-key merge must keep both.
    @Test
    func simultaneousChangesToDifferentKeysOnDifferentDevicesAreBothKept() async {
        let store = FakeUbiquitousStore()
        let threadingKey = "listDisplay.threading"
        let unreadOnlyKey = "listDisplay.unreadOnly"
        let baseline = SettingsCloudPayload(
            values: [threadingKey: .bool(true), unreadOnlyKey: .bool(false)], updatedAt: epoch
        )
        store.seed(baseline, key: "settings.v2")

        // Device A already synced this exact baseline.
        let localA = FakeLocalSettingsDirectory()
        localA.snapshot = baseline
        localA.values = [threadingKey: .bool(true), unreadOnlyKey: .bool(false)]

        // Device B, independently, also already synced this same baseline,
        // then the user flips its `unreadOnly` toggle on (leaving `threading`
        // untouched).
        let localB = FakeLocalSettingsDirectory()
        localB.snapshot = baseline
        localB.values = [threadingKey: .bool(true), unreadOnlyKey: .bool(true)]
        let engineB = makeEngine(store: store, local: localB, now: { self.later })

        let resultB = await engineB.reconcile()
        #expect(resultB == .pushed, "B only changed its own key; nothing to pull from a cloud it's already caught up with")
        #expect(store.currentPayload(key: "settings.v2")?.values == [threadingKey: .bool(true), unreadOnlyKey: .bool(true)])

        // Meanwhile (before device A ever saw B's push), the user flips A's
        // `threading` toggle off, leaving `unreadOnly` untouched on A.
        localA.values = [threadingKey: .bool(false), unreadOnlyKey: .bool(false)]
        let muchLater = Date(timeIntervalSince1970: 1_700_000_200)
        let engineA = makeEngine(store: store, local: localA, now: { muchLater })

        let resultA = await engineA.reconcile()

        #expect(resultA == .merged, "A must both push its own newer threading change and pull B's newer unreadOnly change in the same reconcile")
        #expect(localA.values == [threadingKey: .bool(false), unreadOnlyKey: .bool(true)], "neither device's change may be discarded")
        let merged: SettingsCloudPayload? = store.currentPayload(key: "settings.v2")
        #expect(merged?.values == [threadingKey: .bool(false), unreadOnlyKey: .bool(true)])
        #expect(merged?.entries[threadingKey]?.updatedAt == muchLater)
        #expect(merged?.entries[unreadOnlyKey]?.updatedAt == later)
    }

    /// Task #144 item 4's per-key counterpart to the pre-#144 "two devices
    /// ping-pong on the same key" test above (`twoDevicePingPongConvergesOnTheNewestValue`)
    /// — both devices start from a common synced baseline, then each changes
    /// a *different* key across two more reconcile rounds; both keys' latest
    /// values must survive every round rather than one key's history
    /// occasionally reverting to the other device's stale value.
    @Test
    func perKeyPingPongAcrossTwoKeysConvergesOnBothLatestValuesIndependently() async {
        let store = FakeUbiquitousStore()
        let keyA = "listDisplay.threading"
        let keyB = "listDisplay.unreadOnly"
        let baseline = SettingsCloudPayload(values: [keyA: .bool(true), keyB: .bool(false)], updatedAt: epoch)
        store.seed(baseline, key: "settings.v2")

        let localA = FakeLocalSettingsDirectory()
        localA.snapshot = baseline
        localA.values = [keyA: .bool(true), keyB: .bool(false)]

        let localB = FakeLocalSettingsDirectory()
        localB.snapshot = baseline
        localB.values = [keyA: .bool(true), keyB: .bool(false)]

        // Round 1: A changes keyA, B changes keyB, A reconciles first.
        localA.values = [keyA: .bool(false), keyB: .bool(false)]
        let roundOneA = makeEngine(store: store, local: localA, now: { self.later })
        #expect(await roundOneA.reconcile() == .pushed)

        localB.values = [keyA: .bool(true), keyB: .bool(true)]
        let muchLater = Date(timeIntervalSince1970: 1_700_000_200)
        let roundOneB = makeEngine(store: store, local: localB, now: { muchLater })
        let roundOneBResult = await roundOneB.reconcile()
        #expect(roundOneBResult == .merged, "B must pull A's newer keyA change while pushing its own newer keyB change")
        #expect(localB.values == [keyA: .bool(false), keyB: .bool(true)], "B keeps its own keyB change and picks up A's keyA change")

        // Round 2: A reconciles once more and must pick up B's keyB change
        // without reverting its own already-newest keyA value.
        let roundTwoA = makeEngine(store: store, local: localA, now: { self.epoch })
        let roundTwoAResult = await roundTwoA.reconcile()
        #expect(roundTwoAResult == .pulled)
        #expect(localA.values == [keyA: .bool(false), keyB: .bool(true)], "A converges on both keys' latest values without losing its own keyA change")
    }

    // MARK: - Disabled gate

    @Test
    func reconcileShortCircuitsWhenDisabled() async {
        let store = FakeUbiquitousStore()
        let local = FakeLocalSettingsDirectory()
        local.values = ["listDisplay.threading": .bool(false)]
        let engine = makeEngine(store: store, local: local, isEnabled: { false })

        let result = await engine.reconcile()

        #expect(result == .disabled)
        #expect(store.setCallCount == 0)
        #expect(local.appliedPayloads.isEmpty)
    }
}
