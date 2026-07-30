import Foundation
import Testing
@testable import AccountCloudSync

/// Thin actor-orchestration coverage for `TemplateCloudSyncEngine` — the
/// merge decisions themselves are already exhaustively covered by
/// `TemplateReconcilerTests` against the pure `TemplateReconciler.plan(...)`
/// function; these tests exist to confirm the engine actually wires that
/// plan up to `LocalTemplateDirectory`/`UbiquitousStoring` correctly for
/// both signatures and mail templates, plus the immediate-push/-deletion
/// methods and the `isEnabled` gate — mirroring
/// `AccountCloudSyncEngineTests`'s shape.
@Suite("TemplateCloudSyncEngine")
struct TemplateCloudSyncEngineTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEngine(
        store: FakeUbiquitousStore = FakeUbiquitousStore(),
        local: FakeLocalTemplateDirectory = FakeLocalTemplateDirectory(),
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) -> TemplateCloudSyncEngine {
        TemplateCloudSyncEngine(store: store, local: local, now: { Date(timeIntervalSince1970: 1_700_000_000) }, isEnabled: isEnabled)
    }

    @Test
    func reconcilePushesALocalOnlySignatureAndMailTemplateToTheCloud() async {
        let store = FakeUbiquitousStore()
        let local = FakeLocalTemplateDirectory()
        local.seedLocalSignature(.fixture(syncId: "sig-1", updatedAt: epoch))
        local.seedLocalMailTemplate(.fixture(syncId: "tpl-1", updatedAt: epoch))
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.disabled == false)
        #expect(store.currentTemplatePayload()?.signatures.map(\.syncId) == ["sig-1"])
        #expect(store.currentTemplatePayload()?.mailTemplates.map(\.syncId) == ["tpl-1"])
    }

    @Test
    func reconcileInsertsACloudOnlySignatureAndMailTemplateLocally() async {
        let store = FakeUbiquitousStore()
        store.seed(TemplateCloudPayload(
            signatures: [.fixture(syncId: "cloud-sig", updatedAt: epoch)],
            mailTemplates: [.fixture(syncId: "cloud-tpl", updatedAt: epoch)]
        ))
        let local = FakeLocalTemplateDirectory()
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.insertedSignatureIds == ["cloud-sig"])
        #expect(summary.insertedMailTemplateIds == ["cloud-tpl"])
        #expect(local.currentSignature("cloud-sig") != nil)
        #expect(local.currentMailTemplate("cloud-tpl") != nil)
    }

    @Test
    func reconcileDeletesALocalSignatureTombstonedByAnotherDevice() async {
        let store = FakeUbiquitousStore()
        store.seed(TemplateCloudPayload(signatureTombstones: [TemplateSyncTombstone(syncId: "sig-1", deletedAt: epoch)]))
        let local = FakeLocalTemplateDirectory()
        local.seedLocalSignature(.fixture(syncId: "sig-1", updatedAt: epoch))
        let engine = makeEngine(store: store, local: local)

        let summary = await engine.reconcile()

        #expect(summary.deletedSignatureIds == ["sig-1"])
        #expect(local.currentSignature("sig-1") == nil)
    }

    @Test
    func pushLocalSignatureChangeWritesImmediatelyWithoutAFullReconcile() async {
        let store = FakeUbiquitousStore()
        let engine = makeEngine(store: store)

        await engine.pushLocalSignatureChange(.fixture(syncId: "sig-new", updatedAt: epoch))

        #expect(store.currentTemplatePayload()?.signatures.map(\.syncId) == ["sig-new"])
    }

    @Test
    func pushLocalSignatureDeletionRecordsATombstoneAndRemovesItFromTheList() async {
        let store = FakeUbiquitousStore()
        store.seed(TemplateCloudPayload(signatures: [.fixture(syncId: "sig-1", updatedAt: epoch)]))
        let engine = makeEngine(store: store)

        await engine.pushLocalSignatureDeletion(syncId: "sig-1")

        let payload = store.currentTemplatePayload()
        #expect(payload?.signatures.isEmpty == true)
        #expect(payload?.signatureTombstones.map(\.syncId) == ["sig-1"])
    }

    @Test
    func pushLocalMailTemplateChangeAndDeletionMirrorTheSignaturePaths() async {
        let store = FakeUbiquitousStore()
        let engine = makeEngine(store: store)

        await engine.pushLocalMailTemplateChange(.fixture(syncId: "tpl-new", updatedAt: epoch))
        #expect(store.currentTemplatePayload()?.mailTemplates.map(\.syncId) == ["tpl-new"])

        await engine.pushLocalMailTemplateDeletion(syncId: "tpl-new")
        let payload = store.currentTemplatePayload()
        #expect(payload?.mailTemplates.isEmpty == true)
        #expect(payload?.mailTemplateTombstones.map(\.syncId) == ["tpl-new"])
    }

    @Test
    func reconcileIsANoOpWhenDisabled() async {
        let store = FakeUbiquitousStore()
        let local = FakeLocalTemplateDirectory()
        local.seedLocalSignature(.fixture(syncId: "sig-1", updatedAt: epoch))
        let engine = makeEngine(store: store, local: local, isEnabled: { false })

        let summary = await engine.reconcile()

        #expect(summary == .disabled)
        #expect(store.currentTemplatePayload() == nil)
    }

    @Test
    func pushLocalSignatureChangeIsANoOpWhenDisabled() async {
        let store = FakeUbiquitousStore()
        let engine = makeEngine(store: store, isEnabled: { false })

        await engine.pushLocalSignatureChange(.fixture(syncId: "sig-1", updatedAt: epoch))

        #expect(store.currentTemplatePayload() == nil)
    }
}
