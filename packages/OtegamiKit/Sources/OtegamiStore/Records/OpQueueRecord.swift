import Foundation
import GRDB

/// A queued offline operation (flag change, move, send, ...), replayed
/// FIFO once the account is connected (M3). `payload` is an
/// operation-kind-specific JSON blob rather than a typed column set, so new
/// operation kinds don't require a schema migration. Schema exists from v1;
/// unused until M3.
public struct OpQueueRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "opQueue"

    public var id: Int64?
    public var accountId: String
    public var kind: String
    public var payload: Data
    public var createdAt: Date
    public var attempts: Int
    public var lastError: String?
    /// When this op becomes eligible for another replay attempt after a
    /// failure (exponential backoff, M3's `OpQueueProcessor`). `nil` means
    /// "eligible now" — the state for a never-yet-attempted op, or a v1/v2
    /// row from before this column existed.
    public var nextRetryAt: Date?

    public init(
        id: Int64? = nil,
        accountId: String,
        kind: String,
        payload: Data,
        createdAt: Date = Date(),
        attempts: Int = 0,
        lastError: String? = nil,
        nextRetryAt: Date? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
        self.attempts = attempts
        self.lastError = lastError
        self.nextRetryAt = nextRetryAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
