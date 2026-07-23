/// IMAP server capabilities relevant to `SyncEngine`'s decisions (whether it
/// can use `CONDSTORE` for flag sync, `QRESYNC` for full resync-free
/// reconnects, `IDLE` for push, or Gmail's extended search/labels).
/// Unrecognized capability strings are dropped rather than represented,
/// since callers only ever branch on the cases below.
public enum IMAPCapability: String, Sendable, Codable, Hashable {
    case idle = "IDLE"
    case condstore = "CONDSTORE"
    case qresync = "QRESYNC"
    case xoauth2 = "XOAUTH2"
    case specialUse = "SPECIAL-USE"
    case gmailExtensions = "X-GM-EXT-1"
    case move = "MOVE"
    case uidPlus = "UIDPLUS"
    case namespace = "NAMESPACE"
}

/// An event delivered while an `IMAPSessionProtocol` is in `IDLE`
/// (RFC 2177). Not exercised until M3; `MailCoreIMAPSession.idle` throws
/// `MailTransportError.notImplemented` until then.
public enum IdleEvent: Sendable {
    /// An untagged `EXISTS` response — the mailbox's message count changed
    /// (new mail, or another client's expunge already reflected).
    case newData
    /// The IDLE command was interrupted (by `DONE`, a timeout requiring
    /// reissue, or a connection error) and should be restarted by the
    /// caller if still desired.
    case interrupted
}
