import Foundation
import GRDB

/// Reads/writes `searchHistory` (新画面構成: 検索画面の「検索履歴」) — the raw
/// query strings a user has actually run, most-recently-used first, tappable
/// to re-run and individually removable.
public enum SearchHistoryQuery {
    /// How many entries the search screen shows at once — a search history
    /// list is a convenience shortcut, not an archive, so an unbounded list
    /// isn't useful past a screenful or two.
    public static let maxEntries = 20

    /// Records that `queryText` was searched — either inserting a new row
    /// or, if this exact text was already searched before, deleting and
    /// re-inserting it so it moves back to the top rather than
    /// accumulating a duplicate (`searchHistory.queryText`'s `UNIQUE`
    /// constraint, v20 migration). Delete-then-reinsert rather than an
    /// in-place `UPDATE` (the same convention `FTSIndexer.upsert` already
    /// uses, for a different reason there) so the re-recorded entry also
    /// gets a fresh, strictly-higher autoincremented `id` — `recent()`
    /// orders by `id DESC` as a tiebreaker after `updatedAt DESC` precisely
    /// so two calls landing within the same `Date()` tick (a real
    /// possibility for back-to-back calls, not just a test artifact) still
    /// resolve deterministically to "most recently touched wins," rather
    /// than leaving the tie to SQLite's unspecified sort order for equal
    /// keys. A blank/whitespace-only query is never recorded (nothing
    /// useful to re-run later).
    public static func record(_ queryText: String, db: Database) throws {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try SearchHistoryRecord.filter(Column("queryText") == trimmed).deleteAll(db)
        var record = SearchHistoryRecord(queryText: trimmed, updatedAt: Date())
        try record.insert(db)
    }

    /// The most recent `maxEntries` queries, newest first — see
    /// `record(_:db:)`'s doc comment for why `id DESC` is a necessary
    /// tiebreaker, not just belt-and-suspenders.
    public static func recent(db: Database) throws -> [SearchHistoryRecord] {
        try SearchHistoryRecord
            .order(Column("updatedAt").desc, Column("id").desc)
            .limit(maxEntries)
            .fetchAll(db)
    }

    public static func delete(id: Int64, db: Database) throws {
        _ = try SearchHistoryRecord.deleteOne(db, key: id)
    }

    public static func deleteAll(db: Database) throws {
        try SearchHistoryRecord.deleteAll(db)
    }
}
