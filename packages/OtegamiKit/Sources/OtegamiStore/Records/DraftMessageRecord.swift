import Foundation
import GRDB
import OtegamiCore

/// A message the user explicitly chose to save for later instead of sending
/// or discarding (M10, plan: "Composer 閉じる時「下書きとして保存/破棄」→ ローカル
/// 保存"). Deliberately its own table rather than reusing `outboxMessage`
/// (`OutboxMessageRecord`'s doc comment) — an outbox row means "queued for
/// `OpQueueProcessor` to send", which a draft explicitly is *not*; giving it
/// a separate table means there's no risk of a draft accidentally being
/// picked up and sent, and no need for a status column to distinguish the
/// two states on what would otherwise be the same row.
///
/// IMAP sync (Drafts IMAP sync milestone): a row here always represents a
/// *pending upload/replace* — either a draft never yet pushed to the
/// server (`serverMailboxId`/`serverUid` both `nil`), or a local edit of a
/// previously-uploaded/-downloaded draft that's about to replace an
/// existing server copy (`serverMailboxId`/`serverUid`/`serverUidValidity`
/// carry the *old* copy's location, read by `OpQueueKind.saveDraft`'s
/// replay right before it deletes that copy and overwrites these three
/// columns with the newly-`APPEND`ed copy's). A draft the user has neither
/// created nor edited in this app — one written directly to the server's
/// Drafts mailbox by another mail client — is deliberately **not** mirrored
/// into a row here at all: `DraftQuery`'s unified query instead reads it
/// straight out of the ordinary `message`/`mailbox` tables (any
/// `MailboxRoleRecord.drafts` mailbox already syncs like any other mailbox
/// — `AccountSyncer.upsert`), and only a *save* of that server-origin draft
/// (`ComposerView`'s `.serverDraft` open path) ever creates a row here.
/// This is what lets closing/discarding a freshly-opened server draft
/// without saving be a true no-op — see `docs/verify.md`'s Drafts sync
/// section for the full "never silently lose data" rationale (both this
/// design and IMAP replace/delete op payloads discard rather than clobber
/// on a `uidValidity` mismatch).
///
/// Attachments picked in the Composer *are* preserved across a
/// save-as-draft/resume round trip (`draftAttachment`, mirroring
/// `outboxAttachment`'s "already staged on disk" contract) — the M10-era
/// "not preserved, シンプル優先" limitation this doc comment used to note is
/// resolved by the Drafts IMAP sync milestone (roadmap: "下書きの添付ファイル").
public struct DraftMessageRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "draftMessage"

    public var id: Int64?
    public var accountId: String

    public var toAddresses: [EmailAddress]
    public var ccAddresses: [EmailAddress]
    public var subject: String
    public var plainTextBody: String

    /// Task #161 (#129 第2段): an HTML rendering of the same body
    /// (`ComposerView.bodySnapshotString`), the same field
    /// `OutboxMessageRecord.htmlBody` already carries for a send — see that
    /// property's doc comment for the full "why HTML alongside plain text"
    /// picture. `nil` for a row this schema predates (v33 migration, no
    /// backfill) or for a draft saved before this task, in which case
    /// resuming it just falls back to the plain-text projection, same as
    /// every draft before this task did. Read by `OpQueueProcessor`'s
    /// `.saveDraft` replay to set `ComposeDraft.htmlBody`, closing the one
    /// gap `PENDING.md`'s Task #129/#156 follow-up section left open on
    /// purpose ("下書きテーブルは他エージェントの担当領域と重ならないよう明示的に
    /// 対象外にした") — resuming a saved draft and pushing it straight to the
    /// server's Drafts mailbox (without reopening it in the Composer first)
    /// now carries formatting there too, not just plain text.
    public var htmlBody: String?

    /// Same meaning as `OutboxMessageRecord.inReplyToMessageId`/`.references`
    /// — preserved so resuming a saved reply draft still sends with the
    /// right threading headers, instead of silently degrading into a
    /// same-subject-but-unthreaded new message.
    public var inReplyToMessageId: String?
    public var references: [String]

    /// The `mailbox` row (a `MailboxRoleRecord.drafts` mailbox) this draft's
    /// most-recently-known server copy lives in, if any. See this type's
    /// doc comment for the full "old copy to replace" lifecycle.
    public var serverMailboxId: Int64?
    /// The UID of that copy, as of `serverUidValidity`.
    public var serverUid: Int64?
    /// `MailboxRecord.uidValidity` as observed when `serverUid` was last
    /// captured — the same staleness guard `SetFlagsOpPayload`/`MoveOpPayload`
    /// use: if the mailbox's *current* `uidValidity` no longer matches,
    /// `serverUid` no longer identifies any real message, and any
    /// replace/delete attempt against it must be skipped rather than
    /// misapplied to whatever message now happens to hold that UID.
    public var serverUidValidity: Int64?

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        accountId: String,
        toAddresses: [EmailAddress],
        ccAddresses: [EmailAddress] = [],
        subject: String,
        plainTextBody: String,
        htmlBody: String? = nil,
        inReplyToMessageId: String? = nil,
        references: [String] = [],
        serverMailboxId: Int64? = nil,
        serverUid: Int64? = nil,
        serverUidValidity: Int64? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.toAddresses = toAddresses
        self.ccAddresses = ccAddresses
        self.subject = subject
        self.plainTextBody = plainTextBody
        self.htmlBody = htmlBody
        self.inReplyToMessageId = inReplyToMessageId
        self.references = references
        self.serverMailboxId = serverMailboxId
        self.serverUid = serverUid
        self.serverUidValidity = serverUidValidity
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
