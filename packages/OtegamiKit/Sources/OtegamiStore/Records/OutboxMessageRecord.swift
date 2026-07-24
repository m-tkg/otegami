import Foundation
import GRDB
import OtegamiCore

/// A message queued for sending (M5): the Composer's local, human-readable
/// "still sending" record, kept separate from `OpQueueRecord.payload`'s
/// opaque JSON blob so the UI (the sidebar's "送信待ち" indicator) can list
/// pending sends without decoding opaque opQueue payloads by kind. One row
/// per compose action; `OpQueueKind.send`'s payload (`SendOpPayload`) only
/// carries this row's id, so `OpQueueProcessor` rebuilds the actual RFC 822
/// message from here at replay time (not at enqueue time) — the same
/// message the moment it's actually sent, not a possibly-stale snapshot.
///
/// Deleted once `OpQueueProcessor` successfully hands the message to SMTP
/// (see its `.send` case's doc comment for why a same-transaction delete —
/// not "mark sent" — is safe: sending is never retried after it actually
/// succeeds, only the best-effort Sent-mailbox copy might still fail). A
/// row that keeps failing (network down, bad SMTP config) simply stays —
/// exactly what "送信待ち" should keep showing until it either succeeds or
/// the backing `opQueue` row hits `OpQueueProcessor.maxAttempts`.
public struct OutboxMessageRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "outboxMessage"

    public var id: Int64?
    public var accountId: String

    public var toAddresses: [EmailAddress]
    public var ccAddresses: [EmailAddress]
    public var bccAddresses: [EmailAddress]
    public var subject: String
    public var plainTextBody: String

    /// The `Message-ID` of the message being replied to, if any. `nil` for
    /// a new (non-reply) message.
    public var inReplyToMessageId: String?
    /// The full `References` chain (oldest first) to write when sending —
    /// already resolved by the Composer (original message's References +
    /// its own Message-ID), not recomputed here.
    public var references: [String]

    public var createdAt: Date

    public init(
        id: Int64? = nil,
        accountId: String,
        toAddresses: [EmailAddress],
        ccAddresses: [EmailAddress] = [],
        bccAddresses: [EmailAddress] = [],
        subject: String,
        plainTextBody: String,
        inReplyToMessageId: String? = nil,
        references: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.toAddresses = toAddresses
        self.ccAddresses = ccAddresses
        self.bccAddresses = bccAddresses
        self.subject = subject
        self.plainTextBody = plainTextBody
        self.inReplyToMessageId = inReplyToMessageId
        self.references = references
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
