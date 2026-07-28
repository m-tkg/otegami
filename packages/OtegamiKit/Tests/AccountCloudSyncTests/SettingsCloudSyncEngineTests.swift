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
        #expect(store.currentPayload(key: "settings.v1")?.values == ["listDisplay.threading": .bool(false)])
        #expect(store.currentPayload(key: "settings.v1")?.updatedAt == later)
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
        store.seed(SettingsCloudPayload(values: ["listDisplay.threading": .bool(false)], updatedAt: epoch), key: "settings.v1")
        let local = FakeLocalSettingsDirectory()
        // This device's in-memory defaults disagree with the cloud —
        // exactly what a freshly wiped `UserDefaults` looks like.
        local.values = ["listDisplay.threading": .bool(true)]
        let engine = makeEngine(store: store, local: local)

        let result = await engine.reconcile()

        #expect(result == .pulled)
        #expect(local.appliedPayloads.map(\.values) == [["listDisplay.threading": .bool(false)]])
        // The cloud payload was not overwritten with this device's defaults.
        #expect(store.currentPayload(key: "settings.v1")?.updatedAt == epoch)
    }

    // MARK: - Steady state

    @Test
    func inSyncWhenLocalMatchesTheLastSyncedSnapshotAndTheCloudIsNotNewer() async {
        let store = FakeUbiquitousStore()
        let snapshot = SettingsCloudPayload(values: ["listDisplay.threading": .bool(true)], updatedAt: epoch)
        store.seed(snapshot, key: "settings.v1")
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
        store.seed(oldSnapshot, key: "settings.v1")
        let local = FakeLocalSettingsDirectory()
        local.snapshot = oldSnapshot
        // The user flipped the toggle on this device since the last sync.
        local.values = ["listDisplay.threading": .bool(false)]
        let engine = makeEngine(store: store, local: local, now: { self.later })

        let result = await engine.reconcile()

        #expect(result == .pushed)
        #expect(store.currentPayload(key: "settings.v1")?.values == ["listDisplay.threading": .bool(false)])
        #expect(store.currentPayload(key: "settings.v1")?.updatedAt == later)
        #expect(await local.lastSyncedSnapshot()?.updatedAt == later)
    }

    @Test
    func cloudNewerThanThisDevicesLastSyncedSnapshotIsPulledDown() async {
        let store = FakeUbiquitousStore()
        let cloudPayload = SettingsCloudPayload(values: ["listDisplay.threading": .bool(false)], updatedAt: later)
        store.seed(cloudPayload, key: "settings.v1")
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
