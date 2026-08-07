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

    /// Like `fetchEnvelopes(mailboxPath:uids: UIDRange:batchSize:)` above,
    /// but scoped to an explicit, possibly non-contiguous set of UIDs
    /// rather than a closed numeric range — the `UIDSet` counterpart of
    /// `fetchFlags(mailboxPath:uids: UIDSet)` (see that method's doc
    /// comment for the identical reasoning). `MailboxSyncer
    /// .applyFlagsDiffAndReconcileUnknown` uses this to re-fetch a handful
    /// of UIDs unknown to a flags-only pass's local snapshot: those UIDs
    /// can be scattered across a huge numeric span on a Gmail-shaped
    /// mailbox (large gaps from archived/expunged messages), so deriving a
    /// single `min...max` `UIDRange` from them — this used to do exactly
    /// that — could fetch thousands of already-known envelopes just to
    /// reconcile a few genuinely unknown ones. Chunking is the caller's
    /// responsibility, same as the `UIDSet` overload above: no internal
    /// `batchSize` chunking, one underlying `FETCH` per call.
    func fetchEnvelopes(mailboxPath: String, uids: UIDSet) async throws -> [FetchedEnvelope]

    /// Fetches `ENVELOPE` + `FLAGS` + a `BODYSTRUCTURE` summary for the most
    /// recent `count` messages in `mailboxPath`, addressed by IMAP
    /// *sequence* number (RFC 3501 §2.3.1.2: 1 is the oldest message
    /// currently present, the mailbox's message count the newest) rather
    /// than UID. `AccountSyncer.performInitialSync`/`MailboxSyncer
    /// .performWindowedResync` use this — not the UID-range overload above —
    /// for the "most recent N messages" initial-sync window specifically
    /// *because* it's immune to the gaps a real mailbox's UID space
    /// accumulates from archived/expunged messages: a UID-range window
    /// assumes the UID space is dense (docs/verify.md, "実機バグ調査: 疎な
    /// UID 帯を持つメールボックスで初期同期が0通になる" — a real Gmail/iCloud
    /// mailbox's `uidNext` reflects every message *ever* placed there, so a
    /// mailbox that currently holds only old survivors far from `uidNext`
    /// can make a UID-range window miss every one of them), while sequence
    /// numbers always mean "the Nth-from-the-end message that currently
    /// exists" regardless of how sparse the underlying UIDs are. `count` is
    /// a ceiling, not a guarantee — a mailbox with fewer than `count`
    /// messages simply returns all of them. `batchSize` behaves like the
    /// UID-based overload's parameter. The mailbox must be selected via
    /// `select(_:)` first.
    ///
    /// - Parameter status: The mailbox's current `MailboxStatus`, from the
    ///   caller's own just-completed `select(_:)` (every call site —
    ///   `AccountSyncer.performInitialSync`, `MailboxSyncer
    ///   .performWindowedResync` — already has one in hand). This method
    ///   used to derive the sequence-number window (`upper - count + 1
    ///   ... upper`) from its own extra `STATUS`-equivalent round trip;
    ///   accepting the caller's already-fresh `status` instead removes that
    ///   duplicate `folderInfoOperation` call (`select`/`status` are the
    ///   same underlying MailCore2 request — see `MailCoreIMAPSession
    ///   .select`'s doc comment — so issuing both back to back doubled a
    ///   round trip for information the caller already had).
    func fetchRecentEnvelopes(mailboxPath: String, count: Int, batchSize: Int, status: MailboxStatus) async throws -> [FetchedEnvelope]

    /// `CONDSTORE`-based incremental fetch: envelopes for messages whose
    /// metadata changed since `modSeq` (RFC 7162), plus — when the server
    /// also supports `QRESYNC` — which UIDs vanished (were expunged) since
    /// then. Requires `IMAPCapability.condstore`. M3;
    /// `ChangedSinceResult.vanishedUIDs` added for Task #79 (see its doc
    /// comment).
    func fetchEnvelopes(mailboxPath: String, changedSince modSeq: UInt64) async throws -> ChangedSinceResult

    /// `CONDSTORE`-based incremental fetch requesting only `FLAGS`, not the
    /// full `ENVELOPE`/`BODYSTRUCTURE`/size the overload above fetches for
    /// every changed message. `MailboxSyncer.incrementalSync`'s CONDSTORE
    /// branch uses this by default — see `ChangedSinceFlagsResult`'s doc
    /// comment for the full reasoning and `IMAPCapability.condstore`
    /// requirement (same as the full-envelope overload).
    func fetchFlags(mailboxPath: String, changedSince modSeq: UInt64) async throws -> ChangedSinceFlagsResult

    /// `UID SEARCH`es `mailboxPath` (already `select`ed) restricted to
    /// `uids`, returning just the subset the server currently still has —
    /// no envelope data fetched at all, only numbers. Task #79's
    /// CONDSTORE-path fallback for detecting server-side `EXPUNGE`s when
    /// `fetchEnvelopes(changedSince:)` can't report them itself
    /// (`ChangedSinceResult.vanishedUIDs == nil` — no `QRESYNC`; this is
    /// Gmail's case, confirmed `CONDSTORE`-only): the caller diffs `uids`
    /// against this result to learn which of its own locally-stored UIDs
    /// no longer exist server-side, the same way the non-`CONDSTORE` path
    /// diffs a full re-fetch (see `MailboxSyncer`'s doc comments for the
    /// full picture).
    func searchExistingUIDs(mailboxPath: String, uids: UIDRange) async throws -> Set<UInt32>

    /// Server-side `SEARCH` (RFC 3501 §6.4.4) for `query` against
    /// `mailboxPath` (already `select`ed) — the IMAP `SEARCH` fallback for
    /// otegami's normally-entirely-local search (`docs/architecture.md`:
    /// "検索は完全ローカル DB"). Matches messages whose `SUBJECT`, `FROM`,
    /// or unencoded body text contains `query` (an `OR` of the three, case-
    /// insensitive per RFC 3501's `SEARCH` semantics) — no envelope data
    /// fetched, only UIDs, same shape as `searchExistingUIDs`. Used by
    /// `SyncEngine.ServerSearchService` when the user explicitly taps
    /// 「サーバーで検索」 (never auto-triggered) to find mail older than the
    /// locally-synced window, or whose body hasn't been downloaded yet —
    /// both invisible to the local FTS index. The caller is responsible for
    /// bounding how many of the returned UIDs it actually ingests (this
    /// method itself applies no result-count cap, mirroring
    /// `searchExistingUIDs`'s own contract — see `docs/architecture.md`'s
    /// pitfall (d) on why a caller must never materialize an IMAP `SEARCH`
    /// result without an upper bound).
    func searchMessages(mailboxPath: String, query: String) async throws -> Set<UInt32>

    /// Server-side `UID SEARCH UNSEEN` against `mailboxPath` (already
    /// `select`ed) — every UID the server currently considers unread, no
    /// envelope data, same numbers-only shape as `searchExistingUIDs`.
    ///
    /// 実機報告「まだローカルにない未読メールが検出できない」: otegami's unread
    /// counts are a plain `COUNT(*)` over locally-stored rows
    /// (`MessageQuery.unreadCounts`), so a mailbox whose backfill hasn't
    /// caught up yet — the normal state for a large account, see
    /// `docs/architecture.md`'s pitfall (l) — reports fewer unread messages
    /// than the server actually has, with no way for the app to even know
    /// it's short. `STATUS` can't fill that gap: MailCore2's
    /// `folderInfoOperation` (what `status(_:)` wraps) exposes
    /// `UIDVALIDITY`/`UIDNEXT`/`HIGHESTMODSEQ`/message count and no
    /// `UNSEEN`. This `SEARCH` gives both halves at once — the true unread
    /// count, and exactly which UIDs to fetch to make the list agree with
    /// it.
    ///
    /// Like `searchMessages`, this applies no result-count cap: the caller
    /// (`UnseenSweeper`) is responsible for bounding how many of the
    /// returned UIDs it actually ingests.
    func searchUnseenUIDs(mailboxPath: String) async throws -> Set<UInt32>

    /// `UID FETCH ... (FLAGS)` for `uids` in `mailboxPath` (already
    /// `select`ed) — just the flags, none of `fetchEnvelopes`'s headers/
    /// `BODYSTRUCTURE`/size. Task #194 (「Pull to refresh が長すぎて終わらない」):
    /// `MailboxSyncer.refetchAndDiffFlags`'s non-`CONDSTORE` flag-sync/
    /// expunge-detection path used to call `fetchEnvelopes` for this —
    /// paying for a full envelope re-fetch (headers, `BODYSTRUCTURE`, Gmail
    /// extension attributes, ...) of every locally-known UID on *every*
    /// sync pass, for a server that doesn't support `CONDSTORE`, just to
    /// learn which flags changed and which UIDs vanished. This is the
    /// lighter-weight fetch that path uses instead — one caller-chosen
    /// range per call (no internal `batchSize` chunking, unlike
    /// `fetchEnvelopes`): `MailboxSyncer` does its own chunking so it can
    /// report progress and check `Task.checkCancellation()` between
    /// chunks, which a single opaque batched call wouldn't allow. Returns
    /// only the UIDs the server actually has within `uids` — a UID present
    /// locally but absent from this result (across every chunk covering
    /// it) is exactly `refetchAndDiffFlags`'s "vanished" signal, the same
    /// as before.
    func fetchFlags(mailboxPath: String, uids: UIDRange) async throws -> [UInt32: MessageFlags]

    /// Like `fetchFlags(mailboxPath:uids:)` above, but scoped to an
    /// explicit, possibly non-contiguous set of UIDs rather than a closed
    /// numeric range. `MailboxSyncer.refetchAndDiffFlags` chunks the
    /// *locally-known UIDs themselves* by count (`AccountSyncer
    /// .fetchBatchSize`) rather than by numeric UID span — a sparse UID
    /// space (Gmail-shaped accounts especially, where archived/expunged
    /// messages leave large gaps) can turn a few hundred locally-known
    /// messages spread across a huge numeric range into many mostly-empty
    /// range chunks via the `UIDRange` overload, each still worth one
    /// round trip for a handful of UIDs. This overload lets that chunking
    /// address the actual known UIDs directly; `MCOIndexSet` (this
    /// package's `MailTransportMailCore` backend) still coalesces
    /// contiguous runs within `uids` into IMAP range syntax on the wire, so
    /// a chunk that happens to be dense costs no more than the `UIDRange`
    /// overload would have.
    func fetchFlags(mailboxPath: String, uids: UIDSet) async throws -> [UInt32: MessageFlags]

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

    /// Copies messages into another mailbox (`COPY`) *without* removing
    /// them from `mailboxPath` — unlike `move(mailboxPath:uids:to:)`, which
    /// always leaves `mailboxPath` without them one way or another. Task
    /// #87 (1): Gmail's "アーカイブ解除" (un-archiving from All Mail back to
    /// INBOX) needs exactly this — Gmail auto-retains every non-Spam/Trash
    /// message in All Mail regardless of label state (see `OpQueueKind
    /// .archive`'s doc comment for the archive side of the same fact), so
    /// restoring the INBOX label is "add it to INBOX too", never "move it
    /// out of All Mail".
    func copy(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws

    /// Permanently removes messages flagged `\Deleted` (`EXPUNGE`). M3/M5.
    func expunge(mailboxPath: String) async throws

    /// Enters `IDLE` on `mailboxPath` and yields an event each time the
    /// server pushes an update, until the stream's `Task` is cancelled.
    /// M3.
    func idle(mailboxPath: String) -> AsyncThrowingStream<IdleEvent, Error>
}
