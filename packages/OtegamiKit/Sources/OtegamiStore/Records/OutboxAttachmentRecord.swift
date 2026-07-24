import Foundation
import GRDB

/// One attachment queued to go out with an `OutboxMessageRecord` (M8).
/// Unlike `AttachmentRecord` (the *received*-side row, whose `localPath`
/// starts `nil` until fetched on demand), a row here is only ever created
/// once its bytes are already sitting at `localPath` — see
/// `AppDatabase`'s v8 migration doc comment for why `ComposerView.send`
/// copies the picked file there before inserting this row at all, rather
/// than inserting first and downloading/copying later.
public struct OutboxAttachmentRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "outboxAttachment"

    public var id: Int64?
    public var outboxMessageId: Int64
    public var filename: String
    /// Full `"type/subtype"` (e.g. `"application/pdf"`), matching
    /// `MailTransport.ComposeAttachment.mimeType`.
    public var mimeType: String
    public var localPath: String
    public var size: Int

    public init(
        id: Int64? = nil,
        outboxMessageId: Int64,
        filename: String,
        mimeType: String,
        localPath: String,
        size: Int = 0
    ) {
        self.id = id
        self.outboxMessageId = outboxMessageId
        self.filename = filename
        self.mimeType = mimeType
        self.localPath = localPath
        self.size = size
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
