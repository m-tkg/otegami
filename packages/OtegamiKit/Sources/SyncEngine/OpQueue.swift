import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore

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
    /// M5: send a composed/replied message. Payload is `SendOpPayload`, a
    /// reference to the `outboxMessage` row carrying the actual draft —
    /// see `SendOpPayload`'s doc comment for why the payload itself stays
    /// this small.
    case send
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

    public static func enqueueSend(
        accountId: String,
        outboxMessageId: Int64,
        db: Database
    ) throws {
        let payload = SendOpPayload(outboxMessageId: outboxMessageId)
        try enqueue(kind: .send, accountId: accountId, payload: payload, db: db)
    }

    private static func enqueue(kind: OpQueueKind, accountId: String, payload: some Encodable, db: Database) throws {
        var record = OpQueueRecord(accountId: accountId, kind: kind.rawValue, payload: try JSONEncoder().encode(payload))
        try record.insert(db)
    }
}
