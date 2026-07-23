import Foundation
import GRDB

/// Mirrors `MailTransport.MailboxRole` without depending on `MailTransport`.
/// See `AccountAuthType` for the rationale.
public enum MailboxRoleRecord: String, Codable, Sendable {
    case inbox
    case all
    case archive
    case drafts
    case flagged
    case junk
    case sent
    case trash
    case none
}

/// A synced mailbox (IMAP folder). One row per `(accountId, path)`; upserted
/// idempotently by `SyncEngine` on every `listMailboxes()` pass.
public struct MailboxRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "mailbox"

    public var id: Int64?
    public var accountId: String

    /// The raw IMAP path (server hierarchy delimiter), e.g. `"INBOX"` or
    /// `"[Gmail]/Sent Mail"`. Used as the identifier in IMAP commands.
    public var path: String
    /// Human-presentable path (delimiter normalized to `"/"`). See
    /// `MailTransport.MailboxInfo.displayPath`.
    public var displayPath: String
    public var delimiter: String?
    public var role: MailboxRoleRecord
    /// `MailTransport.MailboxAttributes.rawValue`.
    public var attributesRaw: Int

    /// RFC 3501 §2.3.1.1. Stored as `Int64` (SQLite has no unsigned
    /// integer type); `UInt32` values always fit.
    public var uidValidity: Int64
    public var uidNext: Int64
    /// RFC 7162 `HIGHESTMODSEQ`; `0` when the server doesn't support
    /// `CONDSTORE`/`QRESYNC` (unused until M3).
    public var highestModSeq: Int64
    public var messageCount: Int
    public var lastSyncedAt: Date?

    public init(
        id: Int64? = nil,
        accountId: String,
        path: String,
        displayPath: String,
        delimiter: String? = nil,
        role: MailboxRoleRecord,
        attributesRaw: Int = 0,
        uidValidity: Int64 = 0,
        uidNext: Int64 = 0,
        highestModSeq: Int64 = 0,
        messageCount: Int = 0,
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.path = path
        self.displayPath = displayPath
        self.delimiter = delimiter
        self.role = role
        self.attributesRaw = attributesRaw
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.highestModSeq = highestModSeq
        self.messageCount = messageCount
        self.lastSyncedAt = lastSyncedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
