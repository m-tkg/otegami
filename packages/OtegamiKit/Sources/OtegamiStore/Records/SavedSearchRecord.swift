import Foundation
import GRDB

/// One user-saved query + filter (+ account scope) combination (検索画面
/// 再構成 Task #86: 検索画面の「保存済み」タブ, v29 migration). Unlike
/// `SearchHistoryRecord` (every query actually run gets recorded
/// automatically, LRU-ish), a row here only ever exists because the user
/// tapped the search field's leading star — see
/// `SavedSearchQuery.toggle(queryText:filter:accountId:db:)`.
public struct SavedSearchRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "savedSearch"

    public var id: Int64?
    public var queryText: String
    /// `SearchFilterOption.rawValue` (`apps/Otegami`) at the time this was
    /// saved. Deliberately a plain `String`, not the enum itself — this
    /// package (`OtegamiStore`) doesn't depend on the app target that
    /// defines `SearchFilterOption`. Decode back via
    /// `SearchFilterOption.persisted(rawValue:)`, which falls back to
    /// `.all` for any value that no longer maps to a current case (e.g. the
    /// retired "英語" chip) rather than losing the row.
    public var filter: String
    /// `nil` = saved with "全部" (全アカウント横断) selected at save time.
    public var accountId: String?
    public var createdAt: Date

    public init(id: Int64? = nil, queryText: String, filter: String, accountId: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.queryText = queryText
        self.filter = filter
        self.accountId = accountId
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
