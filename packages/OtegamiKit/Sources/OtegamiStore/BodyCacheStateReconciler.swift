import Foundation
import GRDB

/// Task #221 (本文キャッシュ不当無効化バグ群): a one-time-per-launch self-heal
/// for `message.bodyState == .fetching` rows left behind by a process kill
/// mid-fetch (`BodyFetcher.performFetch` sets `.fetching` *before* the
/// network call, then reverts to `.fetched`/`.notFetched` once it
/// completes or fails — a kill in between skips that revert entirely, and
/// the stale `.fetching` value is what actually gets persisted).
///
/// A row stuck at `.fetching` self-heals from neither direction otherwise:
/// `MessageQuery`'s cache-hit checks require `.fetched` (so the message
/// looks perpetually not-yet-cached even if its body is sitting right
/// there in `messageBody`), and `BodyFetcher.prefetchRecent`'s candidate
/// query requires `.notFetched` (so it's also invisible to the
/// self-healing prefetch pass that would otherwise just re-fetch it).
/// Nothing else in this codebase ever revisits a `.fetching` row once
/// `performFetch` moves on, so without this reconciler it stays wrong
/// forever.
public enum BodyCacheStateReconciler {
    /// Moves every `.fetching` row to `.fetched` (if a `messageBody` row
    /// already exists for it — the fetch actually finished writing the
    /// body before getting killed before its own final `bodyState` update)
    /// or `.notFetched` (no `messageBody` row — the fetch never got that
    /// far), so a caller's next read of it either serves the cache it
    /// already has or is eligible for a normal re-fetch. `AppEnvironment`
    /// runs this once at every launch, the same "cheap once caught up, so
    /// running it again costs effectively nothing" self-heal shape as
    /// `FTSIndexer.backfillIfNeeded` — in normal operation (no kill since
    /// the last launch) this finds nothing and is a single indexed scan.
    ///
    /// Deliberately DB-only (no network, no `AppDatabase`/suspension
    /// awareness): this only ever rewrites a stuck `bodyState` value using
    /// data already local to this device, so `DatabaseSuspensionSupport
    /// .isSuspensionError` never needs to distinguish anything here — a
    /// failure just means "try again next launch", which the caller's
    /// existing best-effort `try?` already gives it for free.
    public static func resetStuckFetchingStates(db: Database) throws {
        let fetchingIds = try Int64.fetchAll(
            db,
            sql: "SELECT id FROM message WHERE bodyState = ?",
            arguments: [MessageBodyState.fetching.rawValue]
        )
        guard !fetchingIds.isEmpty else { return }

        for messageId in fetchingIds {
            let hasBody = try Int.fetchOne(
                db, sql: "SELECT 1 FROM messageBody WHERE messageId = ?", arguments: [messageId]
            ) != nil
            let resolvedState: MessageBodyState = hasBody ? .fetched : .notFetched
            try db.execute(
                sql: "UPDATE message SET bodyState = ? WHERE id = ?",
                arguments: [resolvedState.rawValue, messageId]
            )
        }
    }
}
