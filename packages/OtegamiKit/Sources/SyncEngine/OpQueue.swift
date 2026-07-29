import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore
import os

/// The operation kinds `OpQueueProcessor` knows how to replay, stored
/// verbatim as `OpQueueRecord.kind`. `markRead`/`markUnread` aren't
/// separate kinds — the plan folds them into `setFlags` (see
/// `SetFlagsOpPayload`'s doc comment), and `delete` is its own kind rather
/// than a pre-resolved `move` so `OpQueueProcessor` can resolve the
/// account's current Trash mailbox at *replay* time (robust to the Trash
/// mailbox only being discovered, or changing id, between enqueue and
/// replay) rather than baking a possibly-stale destination mailbox id in
/// at enqueue time.
public enum OpQueueKind: String, Sendable {
    case setFlags
    case move
    case delete
    /// D8 スワイプ設定「迷惑メールにする」: a `move` to whatever mailbox has
    /// `MailboxRole.junk` for this account *at replay time* — same
    /// "resolve/self-heal at replay, not enqueue" shape as `.delete`'s
    /// Trash resolution (`OpQueueKind`'s own doc comment on why), reused
    /// here for the "Junk が無ければ Trash 自動作成と同じパターンで対処" requirement.
    /// Payload is `JunkOpPayload`, structurally identical to
    /// `DeleteOpPayload` but kept as its own type — matching this file's
    /// existing convention of one payload type per `OpQueueKind` rather
    /// than reusing an unrelated kind's type for a coincidentally-identical
    /// shape.
    case junk
    /// M5: send a composed/replied message. Payload is `SendOpPayload`, a
    /// reference to the `outboxMessage` row carrying the actual draft —
    /// see `SendOpPayload`'s doc comment for why the payload itself stays
    /// this small.
    case send
    /// Drafts IMAP sync: `APPEND` a `draftMessage` row to the account's
    /// Drafts mailbox, replacing (best-effort `\Deleted`+`EXPUNGE`) whatever
    /// server copy that row already knew about. Payload is
    /// `SaveDraftOpPayload`, a reference to the row — same "rebuild from the
    /// row at replay time" pattern `SendOpPayload` already uses.
    case saveDraft
    /// Drafts IMAP sync: delete one message from a Drafts mailbox by UID
    /// (best-effort `\Deleted`+`EXPUNGE`, discarded on a `uidValidity`
    /// mismatch like every other UID-addressed op). Used both for
    /// `DraftsView`'s explicit delete and, via `.send`'s replay, for
    /// cleaning up a sent message's now-redundant Drafts copy.
    case deleteDraft
    /// "アーカイブ": resolved at *replay* time, not enqueue time — same
    /// "self-heal against current server state" shape as `.delete`/`.junk`,
    /// but with an extra branch on `account.kind`. A pre-resolved `move` to
    /// a locally-known `MailboxRole.archive` mailbox (the original
    /// implementation) is wrong for Gmail specifically: Gmail has no
    /// `\Archive`-flagged folder at all (its "All Mail" advertises `\All`,
    /// which this app maps to `MailboxRole.all`, not `.archive` — see
    /// `MailCoreIMAPSession+Mapping.role(for:path:)`), so that lookup always
    /// came back `nil` and archiving silently did nothing on a real Gmail
    /// account. Gmail's own archive semantics are "remove the label", not
    /// "move the message": `OpQueueProcessor` branches on `account.kind ==
    /// .gmail` and, for Gmail, just `STORE +FLAGS \Deleted` +`EXPUNGE`s the
    /// *source* mailbox (no COPY) — Gmail auto-keeps every non-Spam/Trash
    /// message in All Mail regardless, so this un-labels it from the source
    /// without deleting it. Every other provider keeps the original
    /// resolve-or-create-then-move behavior (mirrors `resolveOrCreateTrash
    /// Mailbox`/`resolveOrCreateJunkMailbox`, now `resolveOrCreateArchive
    /// Mailbox`). Payload is `ArchiveOpPayload`, structurally identical to
    /// `DeleteOpPayload`/`JunkOpPayload`.
    case archive
    /// Task #87 (1): "アーカイブ解除" — the reverse of `.archive`, resolved at
    /// *replay* time exactly the same way (self-heal against current
    /// server state, branching on `account.kind`). Every other provider:
    /// a plain `move` from wherever the message currently sits (its
    /// Archive-role mailbox — `.archive`'s own destination) back to the
    /// account's INBOX-role mailbox. Gmail: `.archive`'s replay never moves
    /// anything (it un-labels the source, leaving the message in All Mail
    /// regardless — see this case's own doc comment above), so the reverse
    /// is "add the INBOX label back", i.e. `COPY` from All Mail to INBOX
    /// (`IMAPSessionProtocol.copy(mailboxPath:uids:to:)`) — never a `move`,
    /// which would incorrectly pull it *out* of All Mail too. Payload is
    /// `UnarchiveOpPayload`, structurally identical to `ArchiveOpPayload`.
    case unarchive
}

/// `setFlags`'s payload carries the **absolute** desired `MessageFlags`
/// for `uids`, not an add/remove delta — replaying it twice (e.g. after a
/// crash mid-`OpQueueProcessor.replay`) converges to the same server-side
/// state either way, which is what makes FIFO replay safe to resume from
/// wherever it left off. This does mean a `STORE FLAGS` (replace) can clear
/// IMAP keywords/flags this app doesn't track locally (only `\Seen` /
/// `\Answered` / `\Flagged` / `\Draft` / `\Deleted` round-trip through
/// `MessageFlags`) — an accepted M3 simplification given the app never
/// surfaces or edits any other flag.
public struct SetFlagsOpPayload: Codable, Sendable, Equatable {
    public var mailboxId: Int64
    /// `MailboxRecord.uidValidity` as observed when this op was enqueued.
    /// `OpQueueProcessor` discards the op instead of replaying it if the
    /// mailbox's *current* `uidValidity` no longer matches — the UIDs it
    /// names have been reassigned to different messages, so applying them
    /// now would silently corrupt the wrong messages' flags.
    public var uidValidity: Int64
    public var uids: [UInt32]
    public var flagsRaw: Int

    public init(mailboxId: Int64, uidValidity: Int64, uids: [UInt32], flagsRaw: Int) {
        self.mailboxId = mailboxId
        self.uidValidity = uidValidity
        self.uids = uids
        self.flagsRaw = flagsRaw
    }
}

/// `move`'s payload; see `SetFlagsOpPayload` for the `uidValidity`
/// staleness-check rationale (identical here).
public struct MoveOpPayload: Codable, Sendable, Equatable {
    public var sourceMailboxId: Int64
    public var uidValidity: Int64
    public var uids: [UInt32]
    public var destinationMailboxId: Int64

    public init(sourceMailboxId: Int64, uidValidity: Int64, uids: [UInt32], destinationMailboxId: Int64) {
        self.sourceMailboxId = sourceMailboxId
        self.uidValidity = uidValidity
        self.uids = uids
        self.destinationMailboxId = destinationMailboxId
    }
}

/// `delete`'s payload: a `move` to whatever mailbox has `MailboxRole.trash`
/// for this account *at replay time* — no `destinationMailboxId` here on
/// purpose (see `OpQueueKind`'s doc comment).
public struct DeleteOpPayload: Codable, Sendable, Equatable {
    public var sourceMailboxId: Int64
    public var uidValidity: Int64
    public var uids: [UInt32]

    public init(sourceMailboxId: Int64, uidValidity: Int64, uids: [UInt32]) {
        self.sourceMailboxId = sourceMailboxId
        self.uidValidity = uidValidity
        self.uids = uids
    }
}

/// `junk`'s payload — see `OpQueueKind.junk`'s doc comment; shape is
/// identical to `DeleteOpPayload`.
public struct JunkOpPayload: Codable, Sendable, Equatable {
    public var sourceMailboxId: Int64
    public var uidValidity: Int64
    public var uids: [UInt32]

    public init(sourceMailboxId: Int64, uidValidity: Int64, uids: [UInt32]) {
        self.sourceMailboxId = sourceMailboxId
        self.uidValidity = uidValidity
        self.uids = uids
    }
}

/// `archive`'s payload — see `OpQueueKind.archive`'s doc comment; shape is
/// identical to `DeleteOpPayload`/`JunkOpPayload`. No `destinationMailboxId`
/// here on purpose, for the same reason `DeleteOpPayload` has none: the
/// destination (or, for Gmail, "no destination at all — just unlabel") is
/// resolved at replay time, not enqueue time.
public struct ArchiveOpPayload: Codable, Sendable, Equatable {
    public var sourceMailboxId: Int64
    public var uidValidity: Int64
    public var uids: [UInt32]

    public init(sourceMailboxId: Int64, uidValidity: Int64, uids: [UInt32]) {
        self.sourceMailboxId = sourceMailboxId
        self.uidValidity = uidValidity
        self.uids = uids
    }
}

/// `unarchive`'s payload — see `OpQueueKind.unarchive`'s doc comment; shape
/// is identical to `ArchiveOpPayload`. `sourceMailboxId` here is wherever
/// the message currently sits (the account's Archive-role mailbox, or —
/// for Gmail — All Mail), the same "where it is now, not where it's
/// going" convention every other payload in this file already uses.
public struct UnarchiveOpPayload: Codable, Sendable, Equatable {
    public var sourceMailboxId: Int64
    public var uidValidity: Int64
    public var uids: [UInt32]

    public init(sourceMailboxId: Int64, uidValidity: Int64, uids: [UInt32]) {
        self.sourceMailboxId = sourceMailboxId
        self.uidValidity = uidValidity
        self.uids = uids
    }
}

/// `send`'s payload: just a reference to the `OutboxMessageRecord` carrying
/// the actual draft (recipients, subject, body, reply headers) — not a
/// duplicate copy of it. Building the RFC 822 message at *replay* time from
/// this row (rather than pre-building it at enqueue time and embedding the
/// bytes here) keeps this payload small and means `OpQueueProcessor` always
/// works from a single source of truth for "what's still queued to send"
/// (`outboxMessage`, which is also what the sidebar's "送信待ち" indicator
/// reads).
public struct SendOpPayload: Codable, Sendable, Equatable {
    public var outboxMessageId: Int64

    public init(outboxMessageId: Int64) {
        self.outboxMessageId = outboxMessageId
    }
}

/// `saveDraft`'s payload: just a reference to the `DraftMessageRecord` row,
/// for the same "single source of truth, rebuilt at replay time" reason
/// `SendOpPayload` stays this small — see its doc comment.
public struct SaveDraftOpPayload: Codable, Sendable, Equatable {
    public var draftMessageId: Int64

    public init(draftMessageId: Int64) {
        self.draftMessageId = draftMessageId
    }
}

/// `deleteDraft`'s payload: a single UID-addressed delete, the same
/// `uidValidity` staleness-check shape `SetFlagsOpPayload`/`MoveOpPayload`/
/// `DeleteOpPayload` all use. Deliberately not "delete this `draftMessage`
/// row" — a server-origin draft (`DraftQuery`'s unified query) has no local
/// row to reference at all, only a `message`/`mailbox` pair; see
/// `DraftMessageRecord`'s doc comment.
public struct DeleteDraftOpPayload: Codable, Sendable, Equatable {
    public var mailboxId: Int64
    public var uidValidity: Int64
    public var uid: UInt32

    public init(mailboxId: Int64, uidValidity: Int64, uid: UInt32) {
        self.mailboxId = mailboxId
        self.uidValidity = uidValidity
        self.uid = uid
    }
}

/// Encoding/decoding + insertion helpers for `opQueue` rows. Kept as plain
/// functions (not a type UI code needs to instantiate) so a view's
/// `db.write { ... }` block can enqueue an op in the same transaction as
/// the local `MessageRecord` mutation it corresponds to — the pattern the
/// plan calls "ローカル DB 即時反映 + enqueue", meant to commit atomically
/// together rather than as two separate writes that could tear if the app
/// is killed in between.
public enum OpQueue {
    public static func enqueueSetFlags(
        accountId: String,
        mailboxId: Int64,
        uidValidity: Int64,
        uids: [UInt32],
        flags: MessageFlags,
        db: Database
    ) throws {
        guard !uids.isEmpty else { return }
        let payload = SetFlagsOpPayload(mailboxId: mailboxId, uidValidity: uidValidity, uids: uids, flagsRaw: flags.rawValue)
        try enqueue(kind: .setFlags, accountId: accountId, payload: payload, db: db)
    }

    public static func enqueueMove(
        accountId: String,
        sourceMailboxId: Int64,
        uidValidity: Int64,
        uids: [UInt32],
        destinationMailboxId: Int64,
        db: Database
    ) throws {
        guard !uids.isEmpty else { return }
        let payload = MoveOpPayload(
            sourceMailboxId: sourceMailboxId,
            uidValidity: uidValidity,
            uids: uids,
            destinationMailboxId: destinationMailboxId
        )
        try enqueue(kind: .move, accountId: accountId, payload: payload, db: db)
    }

    public static func enqueueDelete(
        accountId: String,
        sourceMailboxId: Int64,
        uidValidity: Int64,
        uids: [UInt32],
        db: Database
    ) throws {
        guard !uids.isEmpty else { return }
        let payload = DeleteOpPayload(sourceMailboxId: sourceMailboxId, uidValidity: uidValidity, uids: uids)
        try enqueue(kind: .delete, accountId: accountId, payload: payload, db: db)
    }

    public static func enqueueJunk(
        accountId: String,
        sourceMailboxId: Int64,
        uidValidity: Int64,
        uids: [UInt32],
        db: Database
    ) throws {
        guard !uids.isEmpty else { return }
        let payload = JunkOpPayload(sourceMailboxId: sourceMailboxId, uidValidity: uidValidity, uids: uids)
        try enqueue(kind: .junk, accountId: accountId, payload: payload, db: db)
    }

    public static func enqueueArchive(
        accountId: String,
        sourceMailboxId: Int64,
        uidValidity: Int64,
        uids: [UInt32],
        db: Database
    ) throws {
        guard !uids.isEmpty else { return }
        let payload = ArchiveOpPayload(sourceMailboxId: sourceMailboxId, uidValidity: uidValidity, uids: uids)
        try enqueue(kind: .archive, accountId: accountId, payload: payload, db: db)
    }

    public static func enqueueUnarchive(
        accountId: String,
        sourceMailboxId: Int64,
        uidValidity: Int64,
        uids: [UInt32],
        db: Database
    ) throws {
        guard !uids.isEmpty else { return }
        let payload = UnarchiveOpPayload(sourceMailboxId: sourceMailboxId, uidValidity: uidValidity, uids: uids)
        try enqueue(kind: .unarchive, accountId: accountId, payload: payload, db: db)
    }

    public static func enqueueSend(
        accountId: String,
        outboxMessageId: Int64,
        db: Database
    ) throws {
        let payload = SendOpPayload(outboxMessageId: outboxMessageId)
        try enqueue(kind: .send, accountId: accountId, payload: payload, db: db)
    }

    public static func enqueueSaveDraft(
        accountId: String,
        draftMessageId: Int64,
        db: Database
    ) throws {
        let payload = SaveDraftOpPayload(draftMessageId: draftMessageId)
        try enqueue(kind: .saveDraft, accountId: accountId, payload: payload, db: db)
    }

    public static func enqueueDeleteDraft(
        accountId: String,
        mailboxId: Int64,
        uidValidity: Int64,
        uid: UInt32,
        db: Database
    ) throws {
        let payload = DeleteDraftOpPayload(mailboxId: mailboxId, uidValidity: uidValidity, uid: uid)
        try enqueue(kind: .deleteDraft, accountId: accountId, payload: payload, db: db)
    }

    /// Task #152 (実機報告「フラグ/アーカイブ操作後、他の受信箱一覧への反映が
    ///遅い」) diagnostics: notice-level (not debug — `docs/verify.md`'s "debug
    /// は log collect に残らない" lesson) OSLog trace of every op this app
    /// enqueues, so a real-device log pull can reconstruct the full
    /// enqueue → replay → targeted-resync timeline for one operation
    /// (`OpQueueProcessor.replay`/`SyncCoordinator.performTargetedResync`
    /// log the later stages under the same "OpReflect" category).
    static let opReflectLogger = Logger(subsystem: "com.mtkg.otegami", category: "OpReflect")

    private static func enqueue(kind: OpQueueKind, accountId: String, payload: some Encodable, db: Database) throws {
        var record = OpQueueRecord(accountId: accountId, kind: kind.rawValue, payload: try JSONEncoder().encode(payload))
        try record.insert(db)
        opReflectLogger.notice("op enqueued kind=\(kind.rawValue, privacy: .public) accountId=\(accountId, privacy: .private) opId=\(record.id ?? -1)")
    }
}
