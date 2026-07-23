import Foundation

/// The result of ``IMAPSessionProtocol/fetchBody(mailboxPath:uid:)`` (M2):
/// a message's body, already parsed and decoded by the backend (charset
/// conversion, `Content-Transfer-Encoding`, `multipart/alternative`
/// selection, ...) so `SyncEngine` never has to speak MIME itself — only
/// `MailTransportMailCore` (which owns the MailCore2 dependency) does.
public struct MessageBodyContent: Sendable, Codable, Hashable {
    /// The message's plain-text rendering, when the backend could produce
    /// one (either from an actual `text/plain` part, or the backend's own
    /// HTML-to-text fallback). `nil` when only HTML is available and the
    /// backend didn't synthesize a plain-text rendering — `SyncEngine`'s
    /// `BodyFetcher` derives one from `html` in that case.
    public var plainText: String?

    /// The message's HTML rendering (body content only, not a full
    /// document — callers wrap it before loading into a web view), when
    /// the message has an HTML part.
    public var html: String?

    /// All attachment/inline parts found while parsing (M2: structure
    /// only, for `attachment` table rows; M8 downloads the actual bytes).
    public var parts: [MIMEPartInfo]

    public init(plainText: String? = nil, html: String? = nil, parts: [MIMEPartInfo] = []) {
        self.plainText = plainText
        self.html = html
        self.parts = parts
    }
}
