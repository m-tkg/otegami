import Foundation
import GRDB

/// One attachment saved with a `DraftMessageRecord` (Drafts IMAP sync
/// milestone, roadmap: "下書きの添付ファイル"). Mirrors `OutboxAttachmentRecord`
/// exactly, including its "bytes already on disk before this row exists"
/// contract — see that type's doc comment. `ComposerView.saveDraft()` stages
/// each pending attachment under `<Application Support>/otegami/Drafts/<uuid>/<filename>`
/// (the draft-side sibling of `.../Outbox/...`) before inserting a row here;
/// `OpQueueProcessor`'s `.saveDraft` replay reads these rows' bytes off disk
/// at replay time, the same "rebuild from the row, not a pre-built snapshot"
/// pattern `outboxAttachment` already follows.
public struct DraftAttachmentRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "draftAttachment"

    public var id: Int64?
    public var draftMessageId: Int64
    public var filename: String
    /// Full `"type/subtype"` (e.g. `"application/pdf"`), matching
    /// `MailTransport.ComposeAttachment.mimeType`.
    public var mimeType: String
    public var localPath: String
    public var size: Int

    public init(
        id: Int64? = nil,
        draftMessageId: Int64,
        filename: String,
        mimeType: String,
        localPath: String,
        size: Int = 0
    ) {
        self.id = id
        self.draftMessageId = draftMessageId
        self.filename = filename
        self.mimeType = mimeType
        self.localPath = localPath
        self.size = size
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
