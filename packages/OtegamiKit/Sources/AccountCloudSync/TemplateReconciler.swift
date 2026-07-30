import Foundation

/// The minimal shape `TemplateReconciler.plan(...)` needs from a synced
/// record type — implemented by `CloudSignatureSnapshot`/
/// `CloudMailTemplateSnapshot` (see each type's doc comment). Kept as a
/// protocol (rather than writing the reconcile logic twice, once per
/// concrete type) so the actual merge algorithm below exists in exactly one
/// place and is exercised by `TemplateReconcilerTests` without touching
/// GRDB, `NSUbiquitousKeyValueStore`, or any actor.
public protocol TemplateSyncSnapshot: Equatable, Sendable {
    /// Cross-device-stable identity — see `CloudSignatureSnapshot.syncId`'s
    /// doc comment.
    var syncId: String { get }
    /// `TemplateReconciler`'s last-writer-wins tiebreaker, mirroring
    /// `AccountCloudSyncEngine`'s use of `CloudAccountSnapshot.updatedAt`.
    var updatedAt: Date { get }
    /// Same-content identity used only to dedupe an independently-created
    /// duplicate — see `CloudSignatureSnapshot.identityKey`'s doc comment.
    var identityKey: String { get }
}

/// What `TemplateReconciler.plan(...)` decided — the pure-data output
/// `TemplateCloudSyncEngine.reconcile()` turns into actual `await`s onto
/// `LocalTemplateDirectory` and the KVS store. Mirrors
/// `AccountCloudSyncEngine.reconcile()`'s four phases (tombstone purge,
/// tombstone-triggered local delete, local-vs-cloud diff, cloud-only
/// insert-with-dedup) but as a plain, synchronous, side-effect-free
/// computation over already-fetched arrays — see this file's doc comment on
/// why that split exists.
public struct TemplateReconcilePlan<Snapshot: TemplateSyncSnapshot>: Equatable {
    /// `syncId`s tombstoned in the cloud payload that this device still has
    /// a local row for — delete them locally.
    public var toDeleteLocally: [String] = []
    /// Cloud-only snapshots (no local row shares their `syncId`) that
    /// aren't a same-content duplicate of something this device already
    /// has — insert them locally as brand-new rows.
    public var toInsertLocally: [Snapshot] = []
    /// Snapshots where the cloud side is newer than this device's local
    /// row sharing the same `syncId` — overwrite the local row's fields.
    public var toUpdateLocally: [Snapshot] = []
    /// The full list `TemplateCloudSyncEngine` should save back to the
    /// cloud payload — every local row (pushed as-is, or as the winner of a
    /// local-newer conflict) plus every surviving cloud entry this device
    /// has no opinion on and every cloud-only entry it just decided to
    /// adopt (echoed back at the same `updatedAt`, not a new timestamp —
    /// adopting a cloud row isn't a local edit).
    public var mergedList: [Snapshot] = []
    /// Tombstones still within the retention window — what
    /// `TemplateCloudSyncEngine` should save back (mirrors
    /// `AccountCloudSyncEngine`'s tombstone-pruning phase).
    public var prunedTombstones: [TemplateSyncTombstone] = []
    /// Cloud-only `syncId`s recognized as a duplicate of a local row under
    /// a *different* `syncId` (`identityKey` matched) — not inserted.
    /// Exposed purely for tests to assert the dedup fired, exactly like
    /// `ReconcileSummary.duplicateCloudAccountIds`.
    public var duplicateCloudSyncIds: [String] = []

    public init(
        toDeleteLocally: [String] = [],
        toInsertLocally: [Snapshot] = [],
        toUpdateLocally: [Snapshot] = [],
        mergedList: [Snapshot] = [],
        prunedTombstones: [TemplateSyncTombstone] = [],
        duplicateCloudSyncIds: [String] = []
    ) {
        self.toDeleteLocally = toDeleteLocally
        self.toInsertLocally = toInsertLocally
        self.toUpdateLocally = toUpdateLocally
        self.mergedList = mergedList
        self.prunedTombstones = prunedTombstones
        self.duplicateCloudSyncIds = duplicateCloudSyncIds
    }
}

/// Pure reconcile algorithm shared by every synced template kind
/// (signatures, mail templates) — see `TemplateCloudSyncEngine` for the
/// thin `actor` that fetches `local`/`cloud`/`tombstones`, calls
/// `plan(...)` once per kind, and applies the result. Kept as a bare
/// `enum` namespace (not a type of its own) since it has no state — every
/// call is a fresh, independent computation, which is exactly what makes it
/// trivial to unit test exhaustively (`TemplateReconcilerTests`).
public enum TemplateReconciler {
    /// - Parameters:
    ///   - local: every synced record this device currently has (already
    ///     fetched from GRDB by the caller).
    ///   - cloud: the KVS payload's current list for this kind.
    ///   - tombstones: the KVS payload's current tombstone list for this
    ///     kind.
    ///   - tombstoneRetention: mirrors `AccountCloudSyncEngine`'s parameter
    ///     of the same name and reasoning (bounds long-run payload size,
    ///     not a correctness requirement for any device reachable within
    ///     the window).
    ///   - now: injected for deterministic tests, exactly like
    ///     `AccountCloudSyncEngine.now`.
    public static func plan<Snapshot: TemplateSyncSnapshot>(
        local: [Snapshot],
        cloud: [Snapshot],
        tombstones: [TemplateSyncTombstone],
        tombstoneRetention: TimeInterval,
        now: Date
    ) -> TemplateReconcilePlan<Snapshot> {
        var plan = TemplateReconcilePlan<Snapshot>()

        let cutoff = now.addingTimeInterval(-tombstoneRetention)
        let freshTombstones = tombstones.filter { $0.deletedAt > cutoff }
        plan.prunedTombstones = freshTombstones
        let tombstoneIds = Set(freshTombstones.map(\.syncId))

        var localById = Dictionary(uniqueKeysWithValues: local.map { ($0.syncId, $0) })
        var cloudById = Dictionary(uniqueKeysWithValues: cloud.map { ($0.syncId, $0) })

        // A tombstoned id has no business lingering in the cloud list
        // itself — mirrors `AccountCloudSyncEngine.reconcile()`'s identical
        // up-front cleanup.
        for id in tombstoneIds { cloudById.removeValue(forKey: id) }

        // Phase: a tombstone for a record this device still has locally
        // means it was deleted elsewhere — delete it here too.
        for id in tombstoneIds where localById[id] != nil {
            plan.toDeleteLocally.append(id)
            localById.removeValue(forKey: id)
        }

        // Phase: every remaining local record either matches the cloud
        // (nothing to do beyond keeping it in the merged list), is missing
        // from the cloud (push it — also how a device's entire pre-existing
        // list migrates up the first time this ever reconciles), or
        // disagrees with the cloud (last-writer-wins by `updatedAt`).
        for (id, localSnapshot) in localById {
            guard let cloudSnapshot = cloudById[id] else {
                cloudById[id] = localSnapshot
                continue
            }
            if cloudSnapshot.updatedAt > localSnapshot.updatedAt {
                plan.toUpdateLocally.append(cloudSnapshot)
                // `cloudById[id]` already holds the winning value — no
                // change needed there.
            } else if localSnapshot.updatedAt > cloudSnapshot.updatedAt {
                cloudById[id] = localSnapshot
            }
            // Equal `updatedAt`: already in sync (both sides agree), keep
            // whichever value is currently in `cloudById` — arbitrary but
            // stable, matching `AccountCloudSyncEngine`'s identical tie
            // handling.
        }

        // Phase: whatever's left in the cloud that this device has neither
        // a local row nor a tombstone for is new — insert it, unless it's a
        // same-content duplicate of a local row under a different `syncId`
        // (two devices independently creating "the same" signature before
        // either had synced — see `CloudSignatureSnapshot.identityKey`'s
        // doc comment). Sorted by `syncId` for the same determinism reason
        // `AccountCloudSyncEngine.reconcile()`'s phase 4 sorts: two devices
        // reconciling the identical payload must converge on the same
        // surviving duplicate, not diverge based on unspecified `Dictionary`
        // iteration order.
        var claimedIdentities = Set(localById.values.map(\.identityKey))
        for (id, cloudSnapshot) in cloudById.sorted(by: { $0.key < $1.key })
        where localById[id] == nil && !tombstoneIds.contains(id) {
            guard !claimedIdentities.contains(cloudSnapshot.identityKey) else {
                plan.duplicateCloudSyncIds.append(id)
                continue
            }
            claimedIdentities.insert(cloudSnapshot.identityKey)
            plan.toInsertLocally.append(cloudSnapshot)
        }

        plan.mergedList = Array(cloudById.values)
        return plan
    }
}
