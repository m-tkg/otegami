import Foundation
import GRDB

/// One remembered search query (新画面構成: 検索履歴, v20 migration). See
/// `AppDatabase`'s v20 migration doc comment for why this is its own table
/// rather than reusing `mailTemplate`'s shape.
public struct SearchHistoryRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "searchHistory"

    public var id: Int64?
    public var queryText: String
    public var updatedAt: Date

    public init(id: Int64? = nil, queryText: String, updatedAt: Date = Date()) {
        self.id = id
        self.queryText = queryText
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
