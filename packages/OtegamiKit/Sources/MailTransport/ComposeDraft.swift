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

    public init(
        from: EmailAddress,
        to: [EmailAddress],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        subject: String,
        plainTextBody: String,
        inReplyTo: String? = nil,
        references: [String] = []
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.plainTextBody = plainTextBody
        self.inReplyTo = inReplyTo
        self.references = references
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
