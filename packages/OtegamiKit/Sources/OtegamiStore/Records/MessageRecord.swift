import Foundation
import GRDB
import OtegamiCore

/// Where a message's body stands in the lazy-fetch pipeline (M2). `M1` only
/// ever writes `.notFetched`.
public enum MessageBodyState: String, Codable, Sendable {
    case notFetched
    case fetching
    case fetched
}

/// A synced message's envelope (no body). One row per `(mailboxId, uid)`,
/// upserted idempotently by `SyncEngine`'s initial/incremental sync.
///
/// `from`/`to`/`cc`/`bcc`/`replyTo` are plain `[EmailAddress]` properties:
/// GRDB's `Codable` record support automatically stores non-primitive
/// `Encodable` properties (arrays, in this case) as JSON in the column, and
/// decodes them back the same way — no manual (de)serialization needed.
public struct MessageRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "message"

    public var id: Int64?
    public var mailboxId: Int64

    /// The message's UID within its mailbox. Stable only as long as
    /// `MailboxRecord.uidValidity` is unchanged (see `FetchedEnvelope.uid`).
    public var uid: Int64

    public var messageId: String?
    public var inReplyTo: String?
    public var subject: String?
    public var normalizedSubject: String?

    public var fromAddresses: [EmailAddress]
    public var toAddresses: [EmailAddress]
    public var ccAddresses: [EmailAddress]
    public var bccAddresses: [EmailAddress]
    public var replyToAddresses: [EmailAddress]

    public var date: Date?
    public var internalDate: Date

    /// `OtegamiCore.MessageFlags.rawValue`.
    public var flagsRaw: Int
    public var size: Int

    /// Gmail's `X-GM-THRID`/`X-GM-MSGID`, stored as `Int64` bit patterns
    /// (SQLite has no unsigned 64-bit type); reinterpret with
    /// `UInt64(bitPattern:)` when read back for Gmail-specific logic (M6+).
    public var gmailThreadId: Int64?
    public var gmailMessageId: Int64?

    public var hasAttachments: Bool
    /// Populated by the `Threader` pass (M4); `nil` until then.
    public var threadId: Int64?
    public var bodyState: MessageBodyState

    public var createdAt: Date
    public var updatedAt: Date

    public var flags: MessageFlags {
        get { MessageFlags(rawValue: flagsRaw) }
        set { flagsRaw = newValue.rawValue }
    }

    public init(
        id: Int64? = nil,
        mailboxId: Int64,
        uid: Int64,
        messageId: String? = nil,
        inReplyTo: String? = nil,
        subject: String? = nil,
        normalizedSubject: String? = nil,
        fromAddresses: [EmailAddress] = [],
        toAddresses: [EmailAddress] = [],
        ccAddresses: [EmailAddress] = [],
        bccAddresses: [EmailAddress] = [],
        replyToAddresses: [EmailAddress] = [],
        date: Date? = nil,
        internalDate: Date,
        flagsRaw: Int = 0,
        size: Int = 0,
        gmailThreadId: Int64? = nil,
        gmailMessageId: Int64? = nil,
        hasAttachments: Bool = false,
        threadId: Int64? = nil,
        bodyState: MessageBodyState = .notFetched,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.mailboxId = mailboxId
        self.uid = uid
        self.messageId = messageId
        self.inReplyTo = inReplyTo
        self.subject = subject
        self.normalizedSubject = normalizedSubject
        self.fromAddresses = fromAddresses
        self.toAddresses = toAddresses
        self.ccAddresses = ccAddresses
        self.bccAddresses = bccAddresses
        self.replyToAddresses = replyToAddresses
        self.date = date
        self.internalDate = internalDate
        self.flagsRaw = flagsRaw
        self.size = size
        self.gmailThreadId = gmailThreadId
        self.gmailMessageId = gmailMessageId
        self.hasAttachments = hasAttachments
        self.threadId = threadId
        self.bodyState = bodyState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
