import Foundation
import GRDB

/// An attachment (or inline part referenced by `cid:`) belonging to a
/// message, populated by body fetch (M2) and fetched-on-demand (M8).
/// `localPath == nil` means the part's content hasn't been downloaded yet.
/// Schema exists from v1; unused until M2/M8.
public struct AttachmentRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "attachment"

    public var id: Int64?
    public var messageId: Int64
    /// The IMAP part specifier, e.g. `"1.2"`. See
    /// `MailTransport.MIMEPartInfo.partId`.
    public var partId: String
    public var filename: String?
    public var mimeType: String
    public var mimeSubtype: String
    public var contentId: String?
    public var isInline: Bool
    public var size: Int
    public var localPath: String?

    public init(
        id: Int64? = nil,
        messageId: Int64,
        partId: String,
        filename: String? = nil,
        mimeType: String,
        mimeSubtype: String,
        contentId: String? = nil,
        isInline: Bool = false,
        size: Int = 0,
        localPath: String? = nil
    ) {
        self.id = id
        self.messageId = messageId
        self.partId = partId
        self.filename = filename
        self.mimeType = mimeType
        self.mimeSubtype = mimeSubtype
        self.contentId = contentId
        self.isInline = isInline
        self.size = size
        self.localPath = localPath
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
