import Foundation
import GRDB

/// A thread of messages within one account (threads don't cross accounts;
/// the unified inbox merges across them at query time). Populated by the
/// `Threader` pass (M4). Schema exists from v1; unused until then.
public struct ThreadRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "thread"

    public var id: Int64?
    public var accountId: String
    public var normalizedSubject: String?
    public var lastMessageDate: Date?
    public var messageCount: Int

    public init(
        id: Int64? = nil,
        accountId: String,
        normalizedSubject: String? = nil,
        lastMessageDate: Date? = nil,
        messageCount: Int = 0
    ) {
        self.id = id
        self.accountId = accountId
        self.normalizedSubject = normalizedSubject
        self.lastMessageDate = lastMessageDate
        self.messageCount = messageCount
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
