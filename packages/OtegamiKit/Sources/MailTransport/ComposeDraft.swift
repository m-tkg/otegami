import Foundation
import OtegamiCore

/// Everything needed to build one outgoing RFC 822 message (M5), independent
/// of whether it's a new message or a reply — the app resolves that
/// distinction (subject "Re:" prefixing, quoted body, `In-Reply-To`/
/// `References`) into this shape before handing it to a message builder.
/// Lives in `MailTransport` (not `MailTransportMailCore`) so `SyncEngine`
/// can depend on the type without depending on MailCore2 itself — matches
/// how `IMAPSessionProtocol`/`SMTPSessionProtocol` keep the abstraction
/// backend-agnostic; the actual MIME construction (`MailCoreMessageBuilder`)
/// is injected into `SyncEngine.OpQueueProcessor` as a closure, the same
/// pattern already used for session factories.
public struct ComposeDraft: Sendable, Equatable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var plainTextBody: String
    /// The `Message-ID` of the message being replied to, if any —
    /// written to the `In-Reply-To` header. `nil` for a new (non-reply)
    /// message.
    public var inReplyTo: String?
    /// The full `References` chain to write (oldest first): the original
    /// message's own `References` with its `Message-ID` appended (RFC 5322
    /// §3.6.4). Empty for a new message.
    public var references: [String]
    /// M8: file attachments to embed. Empty for a plain-text-only message
    /// (every M1–M7 draft). A reply never carries the original message's
    /// own attachments forward (plan: "返信時の元添付は引き継がない" — standard
    /// mail-client behavior) — only whatever the user newly attaches in
    /// `ComposerView` for *this* draft.
    public var attachments: [ComposeAttachment]

    public init(
        from: EmailAddress,
        to: [EmailAddress],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        subject: String,
        plainTextBody: String,
        inReplyTo: String? = nil,
        references: [String] = [],
        attachments: [ComposeAttachment] = []
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.plainTextBody = plainTextBody
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
    }
}

/// One file to embed as a MIME attachment when building a `ComposeDraft`
/// into RFC 822 bytes (M8). `filename` carries Japanese/non-ASCII text
/// verbatim as a plain Swift `String` — encoding it for the wire (RFC 2231/
/// 2047) is `MailCoreMessageBuilder`'s job, the same "backend owns MIME
/// encoding" split `ComposeDraft.subject`/`.plainTextBody` already follow.
public struct ComposeAttachment: Sendable, Equatable {
    public var filename: String
    /// Full `"type/subtype"` (e.g. `"image/png"`, `"application/pdf"`).
    public var mimeType: String
    public var data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

/// The result of rendering a `ComposeDraft` to RFC 822 bytes: the data to
/// hand to `SMTPSessionProtocol.sendMessage`/`IMAPSessionProtocol.append`,
/// plus the `Message-ID` the builder generated for it.
public struct BuiltMessage: Sendable, Equatable {
    public var data: Data
    public var messageId: String

    public init(data: Data, messageId: String) {
        self.data = data
        self.messageId = messageId
    }
}
