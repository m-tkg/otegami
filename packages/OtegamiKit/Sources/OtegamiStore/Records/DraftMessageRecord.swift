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
/// Local-only: there is no IMAP `Drafts` mailbox sync for these (a real
/// mailbox with `MailboxRoleRecord.drafts` may still exist per-account from
/// `AccountSyncer`'s mailbox listing — that's the server's own Drafts
/// folder, a completely separate thing from this table). See
/// `docs/roadmap.md` for syncing local drafts to the server's Drafts
/// mailbox as a future item.
///
/// Attachments picked in the Composer are **not** preserved across a
/// save-as-draft/resume round trip (plan: "シンプル優先") — only the text
/// fields. `ComposerView.saveDraft()`'s doc comment has the rationale.
public struct DraftMessageRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "draftMessage"

    public var id: Int64?
    public var accountId: String

    public var toAddresses: [EmailAddress]
    public var ccAddresses: [EmailAddress]
    public var subject: String
    public var plainTextBody: String

    /// Same meaning as `OutboxMessageRecord.inReplyToMessageId`/`.references`
    /// — preserved so resuming a saved reply draft still sends with the
    /// right threading headers, instead of silently degrading into a
    /// same-subject-but-unthreaded new message.
    public var inReplyToMessageId: String?
    public var references: [String]

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        accountId: String,
        toAddresses: [EmailAddress],
        ccAddresses: [EmailAddress] = [],
        subject: String,
        plainTextBody: String,
        inReplyToMessageId: String? = nil,
        references: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.toAddresses = toAddresses
        self.ccAddresses = ccAddresses
        self.subject = subject
        self.plainTextBody = plainTextBody
        self.inReplyToMessageId = inReplyToMessageId
        self.references = references
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
