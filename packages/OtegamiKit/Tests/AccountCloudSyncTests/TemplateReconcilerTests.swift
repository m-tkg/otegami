import Foundation
import Testing
@testable import AccountCloudSync

/// Exercises `TemplateReconciler.plan(...)` directly — the pure algorithm
/// behind `TemplateCloudSyncEngine.reconcile()` (Task #186), with no actor/
/// GRDB/KVS store involved at all. Uses `CloudSignatureSnapshot` as the
/// concrete `TemplateSyncSnapshot` throughout (the algorithm is generic —
/// `CloudMailTemplateSnapshot` goes through the exact same code path, so
/// `TemplateCloudSyncEngineTests` covers that type instead of duplicating
/// every case here).
@Suite("TemplateReconciler")
struct TemplateReconcilerTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let retention: TimeInterval = 90 * 24 * 3600

    private func plan(
        local: [CloudSignatureSnapshot] = [],
        cloud: [CloudSignatureSnapshot] = [],
        tombstones: [TemplateSyncTombstone] = [],
        now: Date? = nil
    ) -> TemplateReconcilePlan<CloudSignatureSnapshot> {
        TemplateReconciler.plan(local: local, cloud: cloud, tombstones: tombstones, tombstoneRetention: retention, now: now ?? epoch)
    }

    @Test
    func localOnlyRecordIsPushed() {
        let result = plan(local: [.fixture(syncId: "s1", updatedAt: epoch)])

        #expect(result.mergedList.map(\.syncId) == ["s1"])
        #expect(result.toInsertLocally.isEmpty)
        #expect(result.toUpdateLocally.isEmpty)
    }

    @Test
    func cloudOnlyRecordIsInsertedLocally() {
        let result = plan(cloud: [.fixture(syncId: "c1", updatedAt: epoch)])

        #expect(result.toInsertLocally.map(\.syncId) == ["c1"])
        #expect(result.mergedList.map(\.syncId) == ["c1"])
    }

    @Test
    func newerCloudRecordWinsOverOlderLocal() {
        let local = CloudSignatureSnapshot.fixture(syncId: "s1", name: "旧", updatedAt: epoch)
        let cloud = CloudSignatureSnapshot.fixture(syncId: "s1", name: "新", updatedAt: epoch.addingTimeInterval(60))

        let result = plan(local: [local], cloud: [cloud])

        #expect(result.toUpdateLocally == [cloud])
        #expect(result.mergedList == [cloud])
    }

    @Test
    func newerLocalRecordWinsOverOlderCloud() {
        let local = CloudSignatureSnapshot.fixture(syncId: "s1", name: "新", updatedAt: epoch.addingTimeInterval(60))
        let cloud = CloudSignatureSnapshot.fixture(syncId: "s1", name: "旧", updatedAt: epoch)

        let result = plan(local: [local], cloud: [cloud])

        #expect(result.toUpdateLocally.isEmpty)
        #expect(result.mergedList == [local])
    }

    @Test
    func matchingUpdatedAtIsTreatedAsAlreadyInSync() {
        let local = CloudSignatureSnapshot.fixture(syncId: "s1", updatedAt: epoch)
        let cloud = CloudSignatureSnapshot.fixture(syncId: "s1", updatedAt: epoch)

        let result = plan(local: [local], cloud: [cloud])

        #expect(result.toUpdateLocally.isEmpty)
        #expect(result.toInsertLocally.isEmpty)
    }

    @Test
    func tombstoneDeletesTheMatchingLocalRecordAndDropsItFromTheMergedList() {
        let local = CloudSignatureSnapshot.fixture(syncId: "s1", updatedAt: epoch)
        let tombstone = TemplateSyncTombstone(syncId: "s1", deletedAt: epoch)

        let result = plan(local: [local], tombstones: [tombstone])

        #expect(result.toDeleteLocally == ["s1"])
        #expect(result.mergedList.isEmpty)
        #expect(result.prunedTombstones == [tombstone])
    }

    @Test
    func expiredTombstoneIsPrunedAndNoLongerDeletesAnything() {
        let local = CloudSignatureSnapshot.fixture(syncId: "s1", updatedAt: epoch)
        let staleTombstone = TemplateSyncTombstone(syncId: "s1", deletedAt: epoch.addingTimeInterval(-retention - 1))

        let result = plan(local: [local], tombstones: [staleTombstone], now: epoch)

        #expect(result.toDeleteLocally.isEmpty)
        #expect(result.prunedTombstones.isEmpty)
        // The tombstone is gone, so `s1` is once again treated as a normal
        // local-only record that should be pushed back up.
        #expect(result.mergedList.map(\.syncId) == ["s1"])
    }

    /// Task #186's counterpart to `AccountCloudSyncEngine`'s重複挿入バグ
    /// regression: two devices independently creating "the same" signature
    /// (same name/body) before either had synced generate two different
    /// `syncId`s — the second one to arrive in a `reconcile()` must not be
    /// inserted as a second local row.
    @Test
    func cloudOnlyRecordMatchingALocalRecordsIdentityIsNotInsertedAsADuplicate() {
        let local = CloudSignatureSnapshot.fixture(syncId: "local-uuid", name: "会社用", body: "よろしくお願いします", updatedAt: epoch)
        let cloudDuplicate = CloudSignatureSnapshot.fixture(syncId: "cloud-uuid", name: "会社用", body: "よろしくお願いします", updatedAt: epoch)

        let result = plan(local: [local], cloud: [cloudDuplicate])

        #expect(result.toInsertLocally.isEmpty)
        #expect(result.duplicateCloudSyncIds == ["cloud-uuid"])
        // The duplicate cloud entry itself isn't purged from the payload —
        // mirrors `AccountCloudSyncEngine`'s "don't delete, just don't
        // insert" precedent (`docs/icloud-sync.md`'s「重複挿入バグ」修正1).
        #expect(Set(result.mergedList.map(\.syncId)) == ["local-uuid", "cloud-uuid"])
    }

    @Test
    func distinctCloudOnlyRecordsWithDifferentIdentitiesAreBothInserted() {
        let cloudA = CloudSignatureSnapshot.fixture(syncId: "a", name: "あいさつ用", updatedAt: epoch)
        let cloudB = CloudSignatureSnapshot.fixture(syncId: "b", name: "会社用", updatedAt: epoch)

        let result = plan(cloud: [cloudA, cloudB])

        #expect(Set(result.toInsertLocally.map(\.syncId)) == ["a", "b"])
    }
}
