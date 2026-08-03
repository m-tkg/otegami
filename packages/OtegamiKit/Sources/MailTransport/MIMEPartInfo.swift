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

    /// This part's raw, already-decoded bytes, when the backend happened to
    /// have them on hand while building this `MIMEPartInfo` and the part is
    /// small enough (see ``maxEmbeddedDataSize``) — `nil` otherwise.
    ///
    /// Body fetch (M2, `MailCoreIMAPSession.fetchBody` via
    /// `fetchParsedMessageOperation`) downloads and parses the *entire*
    /// RFC822 message, attachments included, so `MCOMessageParser` already
    /// holds every part's bytes in memory by the time
    /// `MailCoreBodyExtraction` builds this value — before Phase 4a,
    /// `BodyFetcher` discarded that and stored metadata only, so opening an
    /// attachment or a `cid:`-referenced inline image forced
    /// `fetchMessageBody(partId:)` to re-download and re-parse the whole
    /// message just to recover bytes that had already been on the wire a
    /// moment earlier. Capped rather than unconditional so this stays a
    /// "preview/inline-image" optimization and doesn't turn a lazy body
    /// fetch into downloading every large attachment eagerly — those still
    /// go through the on-demand `AttachmentFetcher.fetchAndStore` path
    /// unchanged.
    public var data: Data?

    /// The largest ``data`` this type will carry — parts over this size
    /// keep `data == nil` here and fall back to the on-demand
    /// `AttachmentFetcher` fetch path, same as before this field existed.
    /// 5 MB is generous for what `data` is actually for (an inline `cid:`
    /// image, a quick preview thumbnail) while still cheap to hold for
    /// every part of every fetched body; a genuinely large attachment
    /// (video, disk image, ...) has no business riding along with a lazy
    /// body fetch just because the bytes happened to already be in memory.
    public static let maxEmbeddedDataSize = 5 * 1024 * 1024

    public init(
        partId: String,
        mimeType: String,
        mimeSubtype: String,
        filename: String? = nil,
        contentId: String? = nil,
        isAttachment: Bool,
        size: Int,
        data: Data? = nil
    ) {
        self.partId = partId
        self.mimeType = mimeType
        self.mimeSubtype = mimeSubtype
        self.filename = filename
        self.contentId = contentId
        self.isAttachment = isAttachment
        self.size = size
        self.data = data
    }
}
