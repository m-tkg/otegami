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

    /// Task #156 (作成画面リッチテキスト化のHTML送信配線): an HTML rendering of
    /// the same body (`RichTextHTMLCoder.encode(RichTextAttributedString
    /// .makeDocument(from:))`, computed by `ComposerView.send()`), or `nil`
    /// for a send this row predates schema-wise (there is no migration
    /// backfill — see `AppDatabase`'s v32 migration doc comment). Read by
    /// `OpQueueProcessor`'s `.send` replay to set `ComposeDraft.htmlBody`,
    /// which makes `MailCoreMessageBuilder.build` emit a
    /// `multipart/alternative` message (`plainTextBody` fallback + this HTML
    /// part) instead of a bare `text/plain` one — the actual SMTP send now
    /// carries the same bold/italic/underline/strikethrough/list/indent
    /// formatting the Composer's rich text editor shows on screen, closing
    /// the gap `PENDING.md`'s Task #129 follow-up section described (the
    /// formatting used to only affect what `saveDraft()`'s local snapshot
    /// compared, never what actually left over SMTP).
    public var htmlBody: String?

    /// The `Message-ID` of the message being replied to, if any. `nil` for
    /// a new (non-reply) message.
    public var inReplyToMessageId: String?
    /// The full `References` chain (oldest first) to write when sending —
    /// already resolved by the Composer (original message's References +
    /// its own Message-ID), not recomputed here.
    public var references: [String]

    /// Set when this send was composed by resuming a draft (local or
    /// server-origin) that has a known server-side Drafts copy — the same
    /// three-column shape as `DraftMessageRecord.serverMailboxId`/
    /// `.serverUid`/`.serverUidValidity`. `OpQueueProcessor`'s `.send`
    /// replay reads these to best-effort delete that now-redundant Drafts
    /// copy once the message has actually been sent (`docs/roadmap.md`:
    /// "送信完了時に...下書きがそのまま残るのは典型的なバグ"). All three `nil` for a
    /// send that never went through a draft (every M1–M10 send).
    public var draftServerMailboxId: Int64?
    public var draftServerUid: Int64?
    public var draftServerUidValidity: Int64?

    public var createdAt: Date

    /// Task #124 (二重送信防止): `nil` until some `OpQueueProcessor.replay`
    /// pass actually claims the right to hand this row to SMTP (see
    /// `OpQueueProcessor.claimSendStart(outboxMessageId:)`'s doc comment).
    /// Non-`nil` means "an attempt owns this send" — a concurrent or
    /// crash-resumed replay pass must not resend while this is set, only
    /// clearing it back to `nil` if *that same claiming attempt* observes
    /// its own SMTP call fail cleanly (so a later attempt may retry
    /// normally). Left set forever once the SMTP call actually succeeds —
    /// moot at that point since the row is deleted in the same replay pass
    /// right after, but exactly what protects a crash between "SMTP
    /// accepted the message" and "the row got deleted" from resending on
    /// the next launch.
    public var sendStartedAt: Date?

    public init(
        id: Int64? = nil,
        accountId: String,
        toAddresses: [EmailAddress],
        ccAddresses: [EmailAddress] = [],
        bccAddresses: [EmailAddress] = [],
        subject: String,
        plainTextBody: String,
        htmlBody: String? = nil,
        inReplyToMessageId: String? = nil,
        references: [String] = [],
        draftServerMailboxId: Int64? = nil,
        draftServerUid: Int64? = nil,
        draftServerUidValidity: Int64? = nil,
        createdAt: Date = Date(),
        sendStartedAt: Date? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.toAddresses = toAddresses
        self.ccAddresses = ccAddresses
        self.bccAddresses = bccAddresses
        self.subject = subject
        self.plainTextBody = plainTextBody
        self.htmlBody = htmlBody
        self.inReplyToMessageId = inReplyToMessageId
        self.references = references
        self.draftServerMailboxId = draftServerMailboxId
        self.draftServerUid = draftServerUid
        self.draftServerUidValidity = draftServerUidValidity
        self.createdAt = createdAt
        self.sendStartedAt = sendStartedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
