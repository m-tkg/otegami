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
    /// How many of this thread's messages are currently unread (`!flags
    /// .contains(.seen)`). Maintained by `ThreadAssigner.recomputeAggregates`
    /// alongside `messageCount`/`lastMessageDate` — not a live query, so
    /// `ThreadRow` can render a count badge without a join. Added in v4.
    public var unreadCount: Int
    /// ピン留め (E9): `true` if *any* message in this thread has
    /// `MessageRecord.isPinnedLocal` set — the OR-aggregate that makes "1通
    /// でもピン留めされたらそのスレッド自体が最上位" possible without a join at
    /// list-query time. Maintained by `ThreadAssigner.recomputeAggregates`,
    /// same as `unreadCount`. Added in v16.
    public var isPinned: Bool

    public init(
        id: Int64? = nil,
        accountId: String,
        normalizedSubject: String? = nil,
        lastMessageDate: Date? = nil,
        messageCount: Int = 0,
        unreadCount: Int = 0,
        isPinned: Bool = false
    ) {
        self.id = id
        self.accountId = accountId
        self.normalizedSubject = normalizedSubject
        self.lastMessageDate = lastMessageDate
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.isPinned = isPinned
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
