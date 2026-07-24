import GRDB

/// Query helpers for `OutboxMessageRecord` (M5): what `SidebarView`'s
/// "送信待ち" row observes.
public enum OutboxQuery {
    public static func request(accountIds: [String]) -> QueryInterfaceRequest<OutboxMessageRecord> {
        OutboxMessageRecord
            .filter(accountIds.contains(Column("accountId")))
            .order(Column("createdAt"))
    }

    public static func observation(accountIds: [String]) -> ValueObservation<ValueReducers.Fetch<[OutboxMessageRecord]>> {
        ValueObservation.tracking { db in try request(accountIds: accountIds).fetchAll(db) }
    }
}
