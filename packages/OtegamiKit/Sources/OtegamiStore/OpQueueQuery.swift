import GRDB

/// Query helpers for `OpQueueRecord` (M10: the "同期エラー" banner). What
/// counts as "permanently failed" (`attempts >= minAttempts`) is a
/// `SyncEngine.OpQueueProcessor` policy (`OpQueueProcessor.maxAttempts`'s
/// doc comment: "After this many failed attempts, an op is left in the
/// table ... for a future UI banner to surface"), not something
/// `OtegamiStore` should hardcode — `OtegamiStore` doesn't depend on
/// `SyncEngine` (the plan's dependency direction: `SyncEngine → OtegamiStore
/// → OtegamiCore`, never the reverse), so every function here takes
/// `minAttempts` as a parameter and the app layer passes
/// `OpQueueProcessor.maxAttempts` through it.
public enum OpQueueQuery {
    public static func failedOps(accountIds: [String], minAttempts: Int, db: Database) throws -> [OpQueueRecord] {
        try OpQueueRecord
            .filter(accountIds.contains(Column("accountId")))
            .filter(Column("attempts") >= minAttempts)
            .order(Column("createdAt"))
            .fetchAll(db)
    }

    public static func failedOpsObservation(accountIds: [String], minAttempts: Int) -> ValueObservation<ValueReducers.Fetch<[OpQueueRecord]>> {
        ValueObservation.tracking { db in try failedOps(accountIds: accountIds, minAttempts: minAttempts, db: db) }
    }
}
