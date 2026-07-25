import Foundation
import OtegamiCore

/// Abstraction over a single IMAP connection/session, implemented by
/// `MailTransportMailCore.MailCoreIMAPSession` (backed by MailCore2) and by
/// test doubles in `SyncEngine`'s test suite. `SyncEngine` depends only on
/// this protocol, never on MailCore2 directly, so the backend can be
/// swapped without touching sync logic.
///
/// Conformers are expected to serialize access to the underlying connection
/// (e.g. as an `actor`) since a single IMAP connection cannot multiplex
/// concurrent commands.
///
/// M1 implements `connect`, `listMailboxes`, `select`, and `fetchEnvelopes`.
/// M2 adds `fetchBody`. The remaining methods are part of the stable
/// protocol surface for M3 (`store`, `changedSince`, `idle`), M5
/// (`append`, `move`), and M8 (`fetchMessageBody`'s raw per-part fetch) so
/// `SyncEngine` can be written against the full shape now; `MailCoreIMAPSession`
/// throws `MailTransportError.notImplemented` for anything not yet wired up.
public protocol IMAPSessionProtocol: Sendable {
    init(config: IMAPConfig)

    /// Opens the TCP connection (applying `IMAPConfig.security`) and
    /// authenticates with `auth`. Throws `.authenticationFailed` on bad
    /// credentials, `.connectionFailed` for anything lower-level.
    func connect(auth: MailAuth) async throws

    /// Closes the connection. Safe to call when not connected.
    func disconnect() async

    /// The capabilities the server advertised at connect time (`CAPABILITY`
    /// / the post-`LOGIN` capability response).
    func capabilities() async throws -> Set<IMAPCapability>

    /// Lists all mailboxes visible to the account, with `SPECIAL-USE`-based
    /// `MailboxRole` inference applied where the server supports it (and a
    /// best-effort name-based fallback — e.g. `"Sent"`, `"Trash"` — where it
    /// doesn't).
    func listMailboxes() async throws -> [MailboxInfo]

    /// `SELECT`s the given mailbox and returns its current sync state.
    /// Required before `fetchEnvelopes`/`store`/`expunge` on that mailbox.
    func select(_ mailboxPath: String) async throws -> MailboxStatus

    /// Creates a new mailbox (`CREATE`) and subscribes to it (`SUBSCRIBE`,
    /// best-effort — some servers auto-subscribe on `CREATE` and treat a
    /// redundant `SUBSCRIBE` as a no-op, others require it before the new
    /// mailbox shows up in a subscribed-only listing). Used by
    /// `OpQueueProcessor`'s delete-op replay to self-heal a server that
    /// never advertised a `Trash`-role mailbox (no `SPECIAL-USE`, and no
    /// mailbox literally named `Trash`) rather than leaving every delete
    /// permanently stuck on `mailboxNotFound`.
    func createMailbox(path: String) async throws

    /// `STATUS`es the given mailbox without changing which mailbox is
    /// currently selected. Used to cheaply poll for new mail on mailboxes
    /// other than the one currently open.
    func status(_ mailboxPath: String) async throws -> MailboxStatus

    /// Fetches `ENVELOPE` + `FLAGS` + a `BODYSTRUCTURE` summary for `uids`
    /// in `mailboxPath` (which must already be `select`ed). `batchSize`
    /// hints how many UIDs to request per underlying `FETCH` command;
    /// implementations may ignore it if the backend has no such notion.
    /// The mailbox must be selected via `select(_:)` first.
    func fetchEnvelopes(mailboxPath: String, uids: UIDRange, batchSize: Int) async throws -> [FetchedEnvelope]

    /// `CONDSTORE`-based incremental fetch: envelopes for messages whose
    /// metadata changed since `modSeq` (RFC 7162). Requires
    /// `IMAPCapability.condstore`. M3.
    func fetchEnvelopes(mailboxPath: String, changedSince modSeq: UInt64) async throws -> [FetchedEnvelope]

    /// Downloads and parses the full message body (M2): fetches the raw
    /// RFC 822 content and hands it to the backend's own MIME parser,
    /// returning already-decoded plain text / HTML plus a flattened list
    /// of attachment/inline parts. `SyncEngine`'s `BodyFetcher` calls this
    /// once per message rather than driving `BODYSTRUCTURE` + per-part
    /// `fetchMessageBody` fetches itself — simpler, and it means MIME
    /// parsing (charset conversion, transfer-encoding, `multipart/
    /// alternative` selection, ...) only ever happens inside
    /// `MailTransportMailCore`, never in transport-agnostic `SyncEngine`.
    /// The mailbox must already be `select`ed.
    func fetchBody(mailboxPath: String, uid: UInt32) async throws -> MessageBodyContent

    /// Downloads raw, undecoded content for one specific MIME part (by the
    /// `BODYSTRUCTURE` part specifier, e.g. `"1.2"`) or the whole message
    /// when `partId` is `nil`. Used for on-demand attachment *data*
    /// download once a part's existence is already known (from
    /// `fetchBody`'s parts list, or `FetchedEnvelope.parts`) — M8, not M2:
    /// M2 only needs `fetchBody`'s already-parsed plain text/HTML to
    /// render a message and enumerate attachment metadata.
    func fetchMessageBody(mailboxPath: String, uid: UInt32, partId: String?) async throws -> Data

    /// Applies a flag mutation to a set of UIDs (`STORE`). M3.
    func store(mailboxPath: String, change: FlagChange) async throws

    /// Appends a message to a mailbox (`APPEND`), e.g. saving a sent
    /// message to `Sent` for servers that don't do this automatically.
    /// Returns the new message's UID when the server supports `UIDPLUS`.
    /// M5.
    func append(mailboxPath: String, messageData: Data, flags: MessageFlags) async throws -> UInt32?

    /// Moves messages between mailboxes (`MOVE` where supported, else
    /// `COPY` + `STORE +FLAGS \Deleted` + `EXPUNGE`). M5.
    func move(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws

    /// Permanently removes messages flagged `\Deleted` (`EXPUNGE`). M3/M5.
    func expunge(mailboxPath: String) async throws

    /// Enters `IDLE` on `mailboxPath` and yields an event each time the
    /// server pushes an update, until the stream's `Task` is cancelled.
    /// M3.
    func idle(mailboxPath: String) -> AsyncThrowingStream<IdleEvent, Error>
}
