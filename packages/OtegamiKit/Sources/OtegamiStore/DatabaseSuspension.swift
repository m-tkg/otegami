import Foundation
import GRDB

/// Task #192 (実機クラッシュ解析: `EXC_CRASH`/`SIGKILL`,
/// `RUNNINGBOARD`/`0xDEAD10CC` — see `AppDatabase.makeConfiguration
/// (observesSuspensionNotifications:)`'s doc comment for the full
/// root-cause writeup and `docs/architecture.md`'s matching Known
/// pitfalls entry).
///
/// Once `Database.suspendNotification` has fired for a `DatabasePool`
/// configured with `observesSuspensionNotifications = true`, GRDB fails any
/// access that would need a *new* SQLite lock with `SQLITE_INTERRUPT` (9) or
/// `SQLITE_ABORT` (4) rather than letting iOS kill the process for holding
/// one — see GRDB's `Documentation.docc/DatabaseSharing.md`, "How to limit
/// the 0xDEAD10CC exception". `DatabaseError.isInterruptionError` (GRDB's
/// own public helper for exactly this pair of result codes) is what this
/// wraps.
///
/// `SyncEngine`'s `AccountSyncer.classify(_:)`/`OpQueueProcessor.replay
/// (account:auth:)` both check this *before* falling back to their normal
/// "real sync failure" handling: a write that only failed because the
/// database is suspended isn't a network hiccup or a server error worth an
/// in-process retry or a persisted `lastSyncError`/`opQueue.lastError`
/// banner — the database resumes (and a normal resync naturally follows) the
/// next time the app returns to `.active`, so retrying *now*, while still
/// suspended, would just fail again immediately for no benefit.
public enum DatabaseSuspensionSupport {
    /// `true` when `error` is the `DatabaseError` GRDB throws for an access
    /// that raced a suspended database — see this type's doc comment.
    public static func isSuspensionError(_ error: Error) -> Bool {
        (error as? DatabaseError)?.isInterruptionError ?? false
    }
}

/// Task #192: dedups the `Database.suspendNotification`/`.resumeNotification`
/// posts `AppEnvironment.suspendSharedDatabaseIfNeeded()`/
/// `.resumeSharedDatabaseIfNeeded()` make from `OtegamiApp
/// .handleScenePhaseChange` — that switch already maps *both* `.background`
/// and `.inactive` to "suspend", so a `.active → .inactive → .background`
/// transition (a completely ordinary backgrounding sequence) would otherwise
/// post `suspendNotification` twice in a row for one real suspend. Positing
/// a redundant post is likely harmless (GRDB's own suspend()/resume() are
/// idempotent), but tracking real state here — rather than relying on that
/// being true forever — also means a caller can tell "did this call actually
/// change anything" for logging/testing, and keeps the state as a plain,
/// GRDB/SwiftUI-independent value type that's simple to unit test in
/// isolation (`DatabaseSuspensionTrackerTests`) without a UI host or a real
/// database.
public actor DatabaseSuspensionTracker {
    private var isSuspended = false

    public init() {}

    /// Returns `true` the first time this is called while not already
    /// suspended (the caller should post `Database.suspendNotification`
    /// only then); `false` on a redundant call, so the caller can skip the
    /// post entirely.
    @discardableResult
    public func markSuspended() -> Bool {
        guard !isSuspended else { return false }
        isSuspended = true
        return true
    }

    /// Returns `true` the first time this is called while suspended (the
    /// caller should post `Database.resumeNotification` only then); `false`
    /// if already resumed (including the initial state).
    @discardableResult
    public func markResumed() -> Bool {
        guard isSuspended else { return false }
        isSuspended = false
        return true
    }
}
