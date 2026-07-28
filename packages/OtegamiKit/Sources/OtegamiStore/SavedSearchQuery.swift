import Foundation
import GRDB

/// Reads/writes `savedSearch` (検索画面再構成 Task #86: 検索画面の「保存済み」
/// タブ) — a user-chosen shortlist of query+filter(+account scope)
/// combinations, toggled by tapping the search field's leading star,
/// tap-to-rerun, swipe-to-remove. Unlike `SearchHistoryQuery` (every query
/// run gets recorded automatically, LRU-ish "move to top on repeat"), a row
/// here only ever comes from an explicit user action, and `toggle` removes
/// it again on a second tap of the same combination rather than bumping it.
public enum SavedSearchQuery {
    /// A convenience shortlist, not an archive — same rationale as
    /// `SearchHistoryQuery.maxEntries`, just a higher ceiling since these
    /// are intentional saves rather than every query ever typed.
    public static let maxEntries = 50

    /// Saves this exact query+filter+account combination, unless it's
    /// already saved — in which case this *removes* it instead (the star is
    /// a toggle, not a one-way "add"). Returns whether the combination is
    /// saved after this call. A blank/whitespace-only query is never saved
    /// (nothing useful to re-run later, same guard `SearchHistoryQuery
    /// .record(_:db:)` applies).
    ///
    /// No `UNIQUE` constraint on `queryText` alone (unlike `searchHistory`):
    /// the same query text saved under two different filters/account scopes
    /// are legitimately different saved searches, so the duplicate check
    /// here is the full `(queryText, filter, accountId)` triple, done in
    /// application code rather than a DB constraint (`accountId`'s `NULL`
    /// values wouldn't collide under a SQL `UNIQUE` the way "全部" should).
    @discardableResult
    public static func toggle(queryText: String, filter: String, accountId: String?, db: Database) throws -> Bool {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var request = SavedSearchRecord
            .filter(Column("queryText") == trimmed)
            .filter(Column("filter") == filter)
        if let accountId {
            request = request.filter(Column("accountId") == accountId)
        } else {
            request = request.filter(Column("accountId") == nil)
        }

        if let existing = try request.fetchOne(db) {
            _ = try existing.delete(db)
            return false
        }

        // 件数上限: 一番古い保存を追い出してから追加する。明示的な保存操作
        // なので `SearchHistoryQuery` と違い「再実行で先頭に戻す」という
        // LRU 的な扱いは無く、単純に作成日時が一番古い1件を切り詰める。
        let count = try SavedSearchRecord.fetchCount(db)
        if count >= maxEntries, let oldest = try SavedSearchRecord.order(Column("createdAt"), Column("id")).fetchOne(db) {
            _ = try oldest.delete(db)
        }

        var record = SavedSearchRecord(queryText: trimmed, filter: filter, accountId: accountId, createdAt: Date())
        try record.insert(db)
        return true
    }

    /// Newest-saved-first — see `SearchHistoryQuery.recent(db:)`'s doc
    /// comment for why `id DESC` is a necessary tiebreaker alongside
    /// `createdAt DESC`, same reasoning applies here. Since `toggle` already
    /// keeps the table at or under `maxEntries`, this never actually
    /// truncates anything in practice — the `.limit` is belt-and-suspenders
    /// against a hypothetical row inserted outside `toggle`.
    public static func recent(db: Database) throws -> [SavedSearchRecord] {
        try SavedSearchRecord
            .order(Column("createdAt").desc, Column("id").desc)
            .limit(maxEntries)
            .fetchAll(db)
    }

    public static func delete(id: Int64, db: Database) throws {
        _ = try SavedSearchRecord.deleteOne(db, key: id)
    }
}
