import Foundation
import GRDB

/// A message's fetched body (plain text and/or HTML), populated lazily by
/// `SyncEngine`'s body fetch (M2). Schema exists from v1; unused until then.
public struct MessageBodyRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "messageBody"

    /// Shares its primary key with `MessageRecord.id` (one body per
    /// message).
    public var messageId: Int64
    public var plainText: String?
    public var html: String?
    public var fetchedAt: Date?

    public init(messageId: Int64, plainText: String? = nil, html: String? = nil, fetchedAt: Date? = nil) {
        self.messageId = messageId
        self.plainText = plainText
        self.html = html
        self.fetchedAt = fetchedAt
    }
}
