import Foundation
import OtegamiCore

/// The result of fetching one message's `ENVELOPE` + `FLAGS` + a
/// `BODYSTRUCTURE` summary — everything `SyncEngine`'s initial sync needs to
/// populate the `message`/`messageReference` tables and render a message
/// list row, without downloading the body.
public struct FetchedEnvelope: Sendable, Codable, Hashable {
    /// The message's UID within the mailbox it was fetched from. Stable
    /// only as long as `MailboxStatus.uidValidity` is unchanged.
    public var uid: UInt32

    /// The `Message-ID` header, including angle brackets, e.g.
    /// `"<abc123@example.com>"`. Servers are not required to guarantee
    /// uniqueness, but in practice it's the closest thing IMAP offers to a
    /// cross-mailbox stable identifier; `nil` if the message has no
    /// `Message-ID` header (rare, but seen in the wild).
    public var messageId: String?

    /// The `In-Reply-To` header, verbatim (a single Message-ID reference).
    public var inReplyTo: String?

    /// The `References` header, split into individual Message-IDs in
    /// header order (oldest first). Used by `Threader`'s JWZ-style
    /// union-find pass.
    public var references: [String]

    public var subject: String?

    public var from: [EmailAddress]
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var replyTo: [EmailAddress]

    /// The `Date` header as parsed by the server/MailCore2 (the sender's
    /// claimed send time). May be absent or unparsable for malformed mail.
    public var date: Date?

    /// `INTERNALDATE` — when the server received the message. Always
    /// present for a real message; used as the sort/threading fallback
    /// when `date` is missing.
    public var internalDate: Date

    public var flags: MessageFlags

    /// `RFC822.SIZE` in bytes.
    public var size: Int

    /// Gmail's `X-GM-THRID`, when the server supports the `X-GM-EXT-1`
    /// capability. Takes priority over `Threader`'s JWZ pass when present.
    public var gmailThreadId: UInt64?

    /// Gmail's `X-GM-MSGID`, when available.
    public var gmailMessageId: UInt64?

    /// Flattened `BODYSTRUCTURE` summary, used to derive `hasAttachments`
    /// and to drive on-demand part fetch later (M2+). Empty for servers
    /// that don't return `BODYSTRUCTURE` on this fetch (shouldn't happen
    /// for `fetchEnvelopes`, but kept optional-safe rather than force-
    /// unwrapped).
    public var parts: [MIMEPartInfo]

    public var hasAttachments: Bool {
        parts.contains { $0.isAttachment }
    }

    public init(
        uid: UInt32,
        messageId: String?,
        inReplyTo: String?,
        references: [String],
        subject: String?,
        from: [EmailAddress],
        to: [EmailAddress],
        cc: [EmailAddress],
        bcc: [EmailAddress],
        replyTo: [EmailAddress],
        date: Date?,
        internalDate: Date,
        flags: MessageFlags,
        size: Int,
        gmailThreadId: UInt64? = nil,
        gmailMessageId: UInt64? = nil,
        parts: [MIMEPartInfo] = []
    ) {
        self.uid = uid
        self.messageId = messageId
        self.inReplyTo = inReplyTo
        self.references = references
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.date = date
        self.internalDate = internalDate
        self.flags = flags
        self.size = size
        self.gmailThreadId = gmailThreadId
        self.gmailMessageId = gmailMessageId
        self.parts = parts
    }
}
