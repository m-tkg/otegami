/// A mailbox's special-use role, per RFC 6154 (`SPECIAL-USE`). `SyncEngine`
/// uses this to place mailboxes in the sidebar (Inbox/Sent/Drafts/Trash/...)
/// without relying on locale-specific display names.
public enum MailboxRole: String, Sendable, Codable, Hashable {
    case inbox
    case all
    case archive
    case drafts
    case flagged
    case junk
    case sent
    case trash
    /// No `SPECIAL-USE` attribute advertised, or an attribute we don't
    /// recognize yet.
    case none
}

/// Server-advertised attributes for a mailbox (RFC 3501 §7.2.2 mailbox flags
/// plus RFC 6154 special-use attributes), independent of the higher-level
/// `MailboxRole` inference done from them.
public struct MailboxAttributes: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// `\Noselect` — the mailbox is a container only; `SELECT` will fail.
    public static let noSelect = MailboxAttributes(rawValue: 1 << 0)
    /// `\NoInferiors` — the mailbox cannot have child mailboxes.
    public static let noInferiors = MailboxAttributes(rawValue: 1 << 1)
    /// `\Marked` — the mailbox has changed since it was last selected.
    public static let marked = MailboxAttributes(rawValue: 1 << 2)
    /// `\Unmarked` — the opposite of `\Marked`.
    public static let unmarked = MailboxAttributes(rawValue: 1 << 3)
    /// `\HasChildren`
    public static let hasChildren = MailboxAttributes(rawValue: 1 << 4)
    /// `\HasNoChildren`
    public static let hasNoChildren = MailboxAttributes(rawValue: 1 << 5)
}

/// A mailbox as returned by `IMAPSessionProtocol.listMailboxes()`, before
/// any per-mailbox `SELECT`/`STATUS` call.
public struct MailboxInfo: Sendable, Codable, Hashable {
    /// The raw IMAP mailbox path (e.g. `"INBOX"`, `"[Gmail]/Sent Mail"`),
    /// using the server's hierarchy delimiter.
    public var path: String

    /// A human-presentable path, with the server's hierarchy delimiter
    /// normalized to `"/"` and any leading namespace prefix removed where
    /// it would be redundant to show. `SyncEngine`/UI should prefer this
    /// over `path` for anything user-facing; `path` remains the identifier
    /// used in subsequent IMAP commands.
    public var displayPath: String

    /// The hierarchy delimiter this mailbox's `path` uses (e.g. `"/"` or
    /// `"."`), as reported by the server. `nil` if the server didn't report
    /// one (flat namespace). A `String` rather than `Character` purely so
    /// this type stays trivially `Codable`; callers can index `.first`.
    public var delimiter: String?

    public var role: MailboxRole
    public var attributes: MailboxAttributes

    public init(
        path: String,
        displayPath: String,
        delimiter: String? = nil,
        role: MailboxRole,
        attributes: MailboxAttributes
    ) {
        self.path = path
        self.displayPath = displayPath
        self.delimiter = delimiter
        self.role = role
        self.attributes = attributes
    }
}

/// A mailbox's synchronization-relevant state as of a `SELECT`/`STATUS`
/// call. Mirrors the GRDB `mailbox` table's sync columns (see the plan's
/// AppDatabase migrator).
public struct MailboxStatus: Sendable, Codable, Hashable {
    /// RFC 3501 §2.3.1.1. When this changes from a previously stored value,
    /// every UID in the mailbox must be treated as reassigned and the
    /// mailbox resynced from scratch.
    public var uidValidity: UInt32

    /// The UID that will be assigned to the next message appended to the
    /// mailbox. New mail since the last sync is `UID FETCH uidNext:*`.
    public var uidNext: UInt32

    /// RFC 7162 (`CONDSTORE`) `HIGHESTMODSEQ`. `0` when the server doesn't
    /// support `CONDSTORE`/`QRESYNC`, in which case flag sync must fall
    /// back to re-fetching `FLAGS` for the synced UID window.
    public var highestModSeq: UInt64

    public var messageCount: Int

    public init(
        uidValidity: UInt32,
        uidNext: UInt32,
        highestModSeq: UInt64,
        messageCount: Int
    ) {
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.highestModSeq = highestModSeq
        self.messageCount = messageCount
    }
}
