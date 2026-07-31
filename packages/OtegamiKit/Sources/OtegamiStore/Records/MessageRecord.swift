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

    /// Plain-text rendering of `fromAddresses` ("Name <address> ...",
    /// `FTSIndexer.composeFromText`), added in v7 (M7) as its own column
    /// because `fromAddresses` is JSON in a `.blob` column — not something
    /// `SearchQuery`'s `LIKE` fallback (or a human reading the row in a DB
    /// browser) can match against directly. Kept in sync with
    /// `fromAddresses` by `AccountSyncer.upsert`; `nil` only for rows
    /// inserted directly by a test that doesn't set it.
    public var fromText: String?

    /// Plain-text mirrors of `toAddresses`/`ccAddresses`, added in v18
    /// (search operators: `to:`/`cc:`) for the exact same reason
    /// `fromText` exists — `toAddresses`/`ccAddresses` are JSON in a
    /// `.blob` column, not something a `LIKE`-based operator match can
    /// search directly. Kept in sync with their address-array counterparts
    /// by `AccountSyncer.upsert`; `nil` only for rows inserted directly by
    /// a test that doesn't set them.
    public var toText: String?
    public var ccText: String?

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

    /// A short, whitespace-normalized preview of the plain-text body
    /// (`SnippetBuilder`, ~120 characters), populated by `SyncEngine
    /// .BodyFetcher` alongside the body itself (M2). `nil` until the body
    /// has been fetched at least once.
    public var snippet: String?

    /// ピン留め (E9): the single source of truth this app orders by — see
    /// `AppDatabase`'s v16 migration doc comment for the full design. Task
    /// #212: always mirrored to/from IMAP `\Flagged` (the former
    /// `PinSettingsStore.syncWithFlaggedKey` opt-out toggle was removed).
    public var isPinnedLocal: Bool

    /// BCP-47 language code (e.g. `"en"`, `"ja"`) of the message body, set
    /// by `SyncEngine.BodyFetcher` via `MessageLanguageDetector` right
    /// after the body is fetched (v15, `docs/translation.md`). `nil` until
    /// then, and also `nil` when the detector isn't confident enough about
    /// very short/ambiguous text to commit to a language.
    public var detectedLanguage: String?

    public var createdAt: Date
    public var updatedAt: Date

    public var flags: MessageFlags {
        get { MessageFlags(rawValue: flagsRaw) }
        set { flagsRaw = newValue.rawValue }
    }

    /// Task #120 (実機報告「アーカイブ解除しても受信箱に pull-to-refresh まで現れない」):
    /// `true` for a message `SyncEngine.MessageRemoval` has relocated to a
    /// new `mailboxId` *ahead of* the server confirming the move (archive/
    /// unarchive/junk/delete's local half now happens immediately, offline-
    /// safe, the same way removing a message from its source mailbox
    /// already did) — `uid` is a synthetic placeholder (`-id`, always
    /// negative and, since `id` is this table's own primary key, always
    /// unique) rather than a real server-assigned UID, since real IMAP UIDs
    /// are always `>= 1` (RFC 3501 §2.3.1.1). `AccountSyncer.upsert`
    /// reconciles this row (adopts the real UID in place, same row `id`,
    /// preserving thread/body-cache/attachment/translation state) the next
    /// time this mailbox's sync actually fetches the moved message's
    /// envelope — matched by `messageId`, see `AccountSyncer
    /// .reconcilePendingRelocation`'s doc comment.
    ///
    /// Every call site that turns `uid` into a real IMAP `UID` (a `UID
    /// FETCH`/`STORE` argument, or a `MAX(uid)`/vanished-UID diff query)
    /// must check this first and skip/defer rather than blindly converting
    /// — `uid <= 0` traps `UInt32(uid)` (unlike `UInt32(exactly:)`, which
    /// safely returns `nil`), and even where it wouldn't trap, a synthetic
    /// placeholder is never a UID the server would recognize.
    public var isPendingRelocation: Bool { uid <= 0 }

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
        fromText: String? = nil,
        toText: String? = nil,
        ccText: String? = nil,
        date: Date? = nil,
        internalDate: Date,
        flagsRaw: Int = 0,
        size: Int = 0,
        gmailThreadId: Int64? = nil,
        gmailMessageId: Int64? = nil,
        hasAttachments: Bool = false,
        threadId: Int64? = nil,
        bodyState: MessageBodyState = .notFetched,
        snippet: String? = nil,
        isPinnedLocal: Bool = false,
        detectedLanguage: String? = nil,
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
        self.fromText = fromText
        self.toText = toText
        self.ccText = ccText
        self.date = date
        self.internalDate = internalDate
        self.flagsRaw = flagsRaw
        self.size = size
        self.gmailThreadId = gmailThreadId
        self.gmailMessageId = gmailMessageId
        self.hasAttachments = hasAttachments
        self.threadId = threadId
        self.bodyState = bodyState
        self.snippet = snippet
        self.isPinnedLocal = isPinnedLocal
        self.detectedLanguage = detectedLanguage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
