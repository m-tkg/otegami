import GRDB

/// Query helpers for `DraftMessageRecord` (M10): what the sidebar's "下書き"
/// row and `DraftsView` observe. Mirrors `OutboxQuery`'s shape.
public enum DraftQuery {
    public static func request(accountIds: [String]) -> QueryInterfaceRequest<DraftMessageRecord> {
        DraftMessageRecord
            .filter(accountIds.contains(Column("accountId")))
            .order(Column("updatedAt").desc)
    }

    public static func observation(accountIds: [String]) -> ValueObservation<ValueReducers.Fetch<[DraftMessageRecord]>> {
        ValueObservation.tracking { db in try request(accountIds: accountIds).fetchAll(db) }
    }
}
