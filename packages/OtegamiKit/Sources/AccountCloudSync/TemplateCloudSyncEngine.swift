import Foundation

/// What `TemplateCloudSyncEngine.reconcile()` actually did — mirrors
/// `ReconcileSummary`'s role, doubled up for the two kinds this engine
/// covers.
public struct TemplateReconcileSummary: Equatable, Sendable {
    public var insertedSignatureIds: [String] = []
    public var updatedSignatureIds: [String] = []
    public var deletedSignatureIds: [String] = []
    public var duplicateCloudSignatureIds: [String] = []
    public var insertedMailTemplateIds: [String] = []
    public var updatedMailTemplateIds: [String] = []
    public var deletedMailTemplateIds: [String] = []
    public var duplicateCloudMailTemplateIds: [String] = []
    /// `true` when `reconcile()` short-circuited because iCloud sync is
    /// toggled off — every other field is empty in that case.
    public var disabled = false

    public init(
        insertedSignatureIds: [String] = [],
        updatedSignatureIds: [String] = [],
        deletedSignatureIds: [String] = [],
        duplicateCloudSignatureIds: [String] = [],
        insertedMailTemplateIds: [String] = [],
        updatedMailTemplateIds: [String] = [],
        deletedMailTemplateIds: [String] = [],
        duplicateCloudMailTemplateIds: [String] = [],
        disabled: Bool = false
    ) {
        self.insertedSignatureIds = insertedSignatureIds
        self.updatedSignatureIds = updatedSignatureIds
        self.deletedSignatureIds = deletedSignatureIds
        self.duplicateCloudSignatureIds = duplicateCloudSignatureIds
        self.insertedMailTemplateIds = insertedMailTemplateIds
        self.updatedMailTemplateIds = updatedMailTemplateIds
        self.deletedMailTemplateIds = deletedMailTemplateIds
        self.duplicateCloudMailTemplateIds = duplicateCloudMailTemplateIds
        self.disabled = disabled
    }

    public static let disabled = TemplateReconcileSummary(disabled: true)
}

/// Owns the `"templates.v1"` iCloud KVS key — `AccountCloudSyncEngine`'s
/// sibling for signatures (F) and mail templates (C8) (Task #186 「iCloud
/// でアカウントの設定以外も全て同期して欲しい」). Every actual merge decision
/// is the pure `TemplateReconciler.plan(...)` function (see its doc
/// comment); this `actor` is deliberately thin — fetch local state, call
/// `plan(...)` once per kind, apply the result, maybe save the payload back.
///
/// **Reuses `AccountCloudSyncEngine`'s exact architecture** rather than
/// inventing a third one from scratch (`docs/icloud-sync.md`'s Task #186
/// section has the full rationale for why this, and not a per-key entry in
/// `SettingsCloudPayload`, is the right shape for these two kinds
/// specifically): same `UbiquitousStoring` abstraction, same `isEnabled`
/// injection (this device's cloud-sync toggle + the Simulator/dev-build
/// guard `AppEnvironment.isCloudSyncPermittedOnThisBuild()` supplies, both
/// shared verbatim with `accountCloudSync`), same `maxPayloadBytes` size
/// guard, same actor-reentrancy payload lock (see
/// `AccountCloudSyncEngine`'s doc comment for the concrete race that lock
/// closes — identical hazard here: `reconcile()` awaits `local
/// .allSignatureSnapshots()`/`.allMailTemplateSnapshots()`, real suspension
/// points a concurrent `pushLocalSignatureChange`/`pushLocalMailTemplate
/// Deletion` could race past without it), same tombstone-based deletion
/// propagation. What's genuinely new is only the identity: `syncId`
/// (`CloudSignatureSnapshot`/`CloudMailTemplateSnapshot`'s doc comments)
/// stands in for `accountId`, since neither record type had a pre-existing
/// UUID-shaped stable id the way `AccountRecord` always has.
///
/// No development-account-style filtering here (`CloudAccountSnapshot
/// .isDevelopmentAccount`'s doc comment) — a signature/template has no
/// notion of "this is a dev/test mail server", so nothing in this engine
/// needs an equivalent guard; the app-layer `isEnabled` closure's Simulator/
/// dev-build gate (shared with `accountCloudSync`) is still the operative
/// protection against this dev machine's own verify runs reaching real
/// iCloud.
public actor TemplateCloudSyncEngine {
    /// Mirrors `AccountCloudSyncEngine.maxPayloadBytes`'s reasoning exactly.
    public static let maxPayloadBytes = 60_000

    private static let payloadKey = "templates.v1"

    private let store: any UbiquitousStoring
    private let local: any LocalTemplateDirectory
    private let tombstoneRetention: TimeInterval
    private let now: @Sendable () -> Date
    private let isEnabled: @Sendable () -> Bool

    /// Same shape (and same reasoning) as `AccountCloudSyncEngine`'s
    /// payload lock.
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
        local: any LocalTemplateDirectory,
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

    /// Full two-way reconcile for both kinds — the app-launch entry point
    /// and the `didChangeExternallyNotification` entry point, shared with
    /// `accountCloudSync`/`settingsCloudSync` (`AppEnvironment.init()`).
    /// Safe (and cheap — a no-op write when nothing changed) to call
    /// repeatedly.
    @discardableResult
    public func reconcile() async -> TemplateReconcileSummary {
        guard isEnabled() else { return .disabled }
        await acquirePayloadLock()
        defer { releasePayloadLock() }

        var payload = loadPayload()
        var payloadChanged = false
        let mergeNow = now()

        let localSignatures = await local.allSignatureSnapshots()
        let signaturePlan = TemplateReconciler.plan(
            local: localSignatures, cloud: payload.signatures, tombstones: payload.signatureTombstones,
            tombstoneRetention: tombstoneRetention, now: mergeNow
        )
        for syncId in signaturePlan.toDeleteLocally { await local.deleteSignatureLocally(syncId: syncId) }
        for snapshot in signaturePlan.toUpdateLocally { await local.updateSignatureFromCloud(snapshot) }
        for snapshot in signaturePlan.toInsertLocally { await local.insertSignatureFromCloud(snapshot) }
        if signaturePlan.mergedList != payload.signatures || signaturePlan.prunedTombstones != payload.signatureTombstones {
            payloadChanged = true
        }
        payload.signatures = signaturePlan.mergedList
        payload.signatureTombstones = signaturePlan.prunedTombstones

        let localMailTemplates = await local.allMailTemplateSnapshots()
        let mailTemplatePlan = TemplateReconciler.plan(
            local: localMailTemplates, cloud: payload.mailTemplates, tombstones: payload.mailTemplateTombstones,
            tombstoneRetention: tombstoneRetention, now: mergeNow
        )
        for syncId in mailTemplatePlan.toDeleteLocally { await local.deleteMailTemplateLocally(syncId: syncId) }
        for snapshot in mailTemplatePlan.toUpdateLocally { await local.updateMailTemplateFromCloud(snapshot) }
        for snapshot in mailTemplatePlan.toInsertLocally { await local.insertMailTemplateFromCloud(snapshot) }
        if mailTemplatePlan.mergedList != payload.mailTemplates || mailTemplatePlan.prunedTombstones != payload.mailTemplateTombstones {
            payloadChanged = true
        }
        payload.mailTemplates = mailTemplatePlan.mergedList
        payload.mailTemplateTombstones = mailTemplatePlan.prunedTombstones

        if payloadChanged { savePayload(payload) }

        return TemplateReconcileSummary(
            insertedSignatureIds: signaturePlan.toInsertLocally.map(\.syncId),
            updatedSignatureIds: signaturePlan.toUpdateLocally.map(\.syncId),
            deletedSignatureIds: signaturePlan.toDeleteLocally,
            duplicateCloudSignatureIds: signaturePlan.duplicateCloudSyncIds,
            insertedMailTemplateIds: mailTemplatePlan.toInsertLocally.map(\.syncId),
            updatedMailTemplateIds: mailTemplatePlan.toUpdateLocally.map(\.syncId),
            deletedMailTemplateIds: mailTemplatePlan.toDeleteLocally,
            duplicateCloudMailTemplateIds: mailTemplatePlan.duplicateCloudSyncIds
        )
    }

    /// Pushes one locally-added/-changed signature to the cloud
    /// immediately, rather than waiting for the next full `reconcile()` —
    /// called right after a local insert/update
    /// (`SignatureTemplateEditView.save()`). A no-op while sync is toggled
    /// off.
    public func pushLocalSignatureChange(_ snapshot: CloudSignatureSnapshot) async {
        guard isEnabled() else { return }
        await acquirePayloadLock()
        defer { releasePayloadLock() }
        var payload = loadPayload()
        payload.signatureTombstones.removeAll { $0.syncId == snapshot.syncId }
        payload.signatures.removeAll { $0.syncId == snapshot.syncId }
        payload.signatures.append(snapshot)
        savePayload(payload)
    }

    /// Records a local signature deletion as a tombstone immediately
    /// (`SignatureTemplatesSettingsView.deleteSignature(_:)`). Must **not**
    /// be called for a deletion that itself originated from a cloud
    /// tombstone — mirrors `AccountCloudSyncEngine.pushLocalDeletion`'s
    /// identical caveat.
    public func pushLocalSignatureDeletion(syncId: String) async {
        guard isEnabled() else { return }
        await acquirePayloadLock()
        defer { releasePayloadLock() }
        var payload = loadPayload()
        payload.signatures.removeAll { $0.syncId == syncId }
        payload.signatureTombstones.removeAll { $0.syncId == syncId }
        payload.signatureTombstones.append(TemplateSyncTombstone(syncId: syncId, deletedAt: now()))
        savePayload(payload)
    }

    /// `pushLocalSignatureChange`'s counterpart for mail templates
    /// (`TemplateEditView.save()`).
    public func pushLocalMailTemplateChange(_ snapshot: CloudMailTemplateSnapshot) async {
        guard isEnabled() else { return }
        await acquirePayloadLock()
        defer { releasePayloadLock() }
        var payload = loadPayload()
        payload.mailTemplateTombstones.removeAll { $0.syncId == snapshot.syncId }
        payload.mailTemplates.removeAll { $0.syncId == snapshot.syncId }
        payload.mailTemplates.append(snapshot)
        savePayload(payload)
    }

    /// `pushLocalSignatureDeletion`'s counterpart for mail templates
    /// (`TemplatesSettingsView.deleteTemplate(_:)`).
    public func pushLocalMailTemplateDeletion(syncId: String) async {
        guard isEnabled() else { return }
        await acquirePayloadLock()
        defer { releasePayloadLock() }
        var payload = loadPayload()
        payload.mailTemplates.removeAll { $0.syncId == syncId }
        payload.mailTemplateTombstones.removeAll { $0.syncId == syncId }
        payload.mailTemplateTombstones.append(TemplateSyncTombstone(syncId: syncId, deletedAt: now()))
        savePayload(payload)
    }

    private func loadPayload() -> TemplateCloudPayload {
        guard let data = store.data(forKey: Self.payloadKey) else { return TemplateCloudPayload() }
        return (try? JSONDecoder.templateCloudSync.decode(TemplateCloudPayload.self, from: data)) ?? TemplateCloudPayload()
    }

    @discardableResult
    private func savePayload(_ payload: TemplateCloudPayload) -> Bool {
        guard let data = try? JSONEncoder.templateCloudSync.encode(payload) else { return false }
        guard data.count <= Self.maxPayloadBytes else { return false }
        store.set(data, forKey: Self.payloadKey)
        store.synchronize()
        return true
    }
}

private extension JSONEncoder {
    static let templateCloudSync: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let templateCloudSync: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
