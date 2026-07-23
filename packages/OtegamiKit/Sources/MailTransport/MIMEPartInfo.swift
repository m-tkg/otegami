import Foundation

/// A summary of one part of a message's MIME structure (from `BODYSTRUCTURE`
/// / MailCore2's `AbstractPart` tree), flattened enough to answer "does this
/// message have attachments" and to drive body/attachment fetch-by-part-id
/// later, without carrying the full recursive structure across the
/// transport boundary.
public struct MIMEPartInfo: Sendable, Codable, Hashable {
    /// The IMAP part specifier (e.g. `"1"`, `"1.2"`, `"TEXT"`), used with
    /// `BODY[<partId>]` to fetch this part's content on demand.
    public var partId: String

    /// MIME type, e.g. `"text"`.
    public var mimeType: String

    /// MIME subtype, e.g. `"plain"`, `"html"`, `"pdf"`.
    public var mimeSubtype: String

    /// The `filename` parameter from `Content-Disposition`/`Content-Type`,
    /// when present.
    public var filename: String?

    /// `Content-ID`, used to resolve `cid:` references from HTML bodies to
    /// inline parts.
    public var contentId: String?

    /// Whether this part's `Content-Disposition` is `attachment` (as
    /// opposed to `inline`).
    public var isAttachment: Bool

    /// Encoded size in bytes, as reported by `BODYSTRUCTURE`.
    public var size: Int

    public init(
        partId: String,
        mimeType: String,
        mimeSubtype: String,
        filename: String? = nil,
        contentId: String? = nil,
        isAttachment: Bool,
        size: Int
    ) {
        self.partId = partId
        self.mimeType = mimeType
        self.mimeSubtype = mimeSubtype
        self.filename = filename
        self.contentId = contentId
        self.isAttachment = isAttachment
        self.size = size
    }
}
