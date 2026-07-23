import Foundation
import GRDB

/// One entry of a message's `References` header (normalized Message-ID
/// tokens, oldest first), used by `Threader`'s JWZ-style union-find pass
/// (M4). `SyncEngine` replaces a message's references wholesale on every
/// resync rather than diffing them.
public struct MessageReferenceRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "messageReference"

    public var id: Int64?
    public var messageId: Int64
    /// A `Message-ID` token from the referencing message's `References`
    /// header (not the numeric `message.id`; the string a `MessageRecord`
    /// might itself have as its own `messageId`).
    public var referenceValue: String
    /// Position within the header, oldest first (index 0 = first
    /// reference), preserved for JWZ ordering.
    public var position: Int

    public init(id: Int64? = nil, messageId: Int64, referenceValue: String, position: Int) {
        self.id = id
        self.messageId = messageId
        self.referenceValue = referenceValue
        self.position = position
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
