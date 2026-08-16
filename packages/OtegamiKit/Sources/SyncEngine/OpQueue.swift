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
    /// 「迷惑メール解除」— the reverse of `.junk`: a `move` from wherever the
    /// message currently sits (its Junk-role mailbox) back to the account's
    /// INBOX-role mailbox, resolved at *replay* time exactly like every
    /// other kind here. No `account.kind` branch (unlike `.unarchive`):
    /// Gmail's Spam **is** a real folder on IMAP, so moving out of it is a
    /// plain `MOVE` for every provider — Gmail re-applies the INBOX label
    /// and drops the Spam one as a side effect of the move itself. INBOX is
    /// a lookup, never a `resolveOrCreate` (`MailboxRoleResolver` never
    /// self-heals `.inbox`), matching `.unarchive`'s own INBOX resolution.
    /// Payload is `UnjunkOpPayload`, structurally identical to
    /// `JunkOpPayload`.
    case unjunk
    /// 「ゴミ箱を空にする」— purges every message `EmptyTrash.commit` already
    /// hard-deleted locally from the server's Trash mailbox too: `STORE
    /// +FLAGS \Deleted` + `EXPUNGE` against the Trash mailbox itself, never
    /// a `move` — there's nowhere left for these messages to go, unlike
    /// every other kind here. One op per "ゴミ箱を空にする" action, carrying
    /// every UID it removed (`EmptyTrashOpPayload`), rather than one op per
    /// message the way `MessageRemoval.commit`'s callers enqueue — see that
    /// payload's doc comment for why batching matters here specifically. No
    /// `account.kind == .gmail` branch needed (unlike `.archive`): Gmail
    /// already treats `\Deleted`+`EXPUNGE` on its own Trash label as a real
    /// permanent delete, the same semantics every other provider has for
    /// its own Trash folder.
    case emptyTrash
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
    /// How `OpQueueProcessor` combines `flagsRaw` with the message's
    /// existing server-side flags via IMAP `STORE` — see `FlagOp`'s doc
    /// comment (`MailTransport`). Defaults to `.replace`, this payload's
    /// original behavior: the caller already knows the message's full
    /// local flag state and wants to write it back verbatim (safe when
    /// the message is already synced). `.add`/`.remove` exist for callers
    /// that only know one flag's *target* state — e.g. marking a message
    /// read from a push notification, where the app has no local copy of
    /// the message at all and a `.replace` would clobber server-side
    /// `\Answered`/`\Flagged`/etc. this app never learned about.
    public var op: FlagOp

    public init(mailboxId: Int64, uidValidity: Int64, uids: [UInt32], flagsRaw: Int, op: FlagOp = .replace) {
        self.mailboxId = mailboxId
        self.uidValidity = uidValidity
        self.uids = uids
        self.flagsRaw = flagsRaw
        self.op = op
    }

    private enum CodingKeys: String, CodingKey {
        case mailboxId, uidValidity, uids, flagsRaw, op
    }

    /// Manual `init(from:)` (not the synthesized one) so an `opQueue` row
    /// persisted before `op` existed — its JSON has no `op` key at all —
    /// still decodes successfully, falling back to `.replace` (this
    /// payload's original, only-ever behavior at the time such a row could
    /// have been written). `encode(to:)` stays synthesized: every payload
    /// written from now on always has all fields, so there's no matching
    /// backward-compat concern on the encode side.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mailboxId = try container.decode(Int64.self, forKey: .mailboxId)
        uidValidity = try container.decode(Int64.self, forKey: .uidValidity)
        uids = try container.decode([UInt32].self, forKey: .uids)
        flagsRaw = try container.decode(Int.self, forKey: .flagsRaw)
        op = try container.decodeIfPresent(FlagOp.self, forKey: .op) ?? .replace
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
    /// See `ArchiveOpPayload.relocatedMessageId`'s doc comment — identical
    /// role, just for `.delete`.
    public var relocatedMessageId: Int64?

    public init(sourceMailboxId: Int64, uidValidity: Int64, uids: [UInt32], relocatedMessageId: Int64? = nil) {
        self.sourceMailboxId = sourceMailboxId
        self.uidValidity = uidValidity
        self.uids = uids
        self.relocatedMessageId = relocatedMessageId
    }
}

/// `junk`'s payload — see `OpQueueKind.junk`'s doc comment; shape is
/// identical to `DeleteOpPayload`.
public struct JunkOpPayload: Codable, Sendable, Equatable {
    public var sourceMailboxId: Int64
    public var uidValidity: Int64
    public var uids: [UInt32]
    /// See `ArchiveOpPayload.relocatedMessageId`'s doc comment — identical
    /// role, just for `.junk`.
    public var relocatedMessageId: Int64?

    public init(sourceMailboxId: Int64, uidValidity: Int64, uids: [UInt32], relocatedMessageId: Int64? = nil) {
        self.sourceMailboxId = sourceMailboxId
        self.uidValidity = uidValidity
        self.uids = uids
        self.relocatedMessageId = relocatedMessageId
    }
}

/// `unjunk`'s payload — see `OpQueueKind.unjunk`'s doc comment; shape is
/// identical to `JunkOpPayload`. `sourceMailboxId` is wherever the message
/// currently sits (the account's Junk-role mailbox), the same "where it is
/// now, not where it's going" convention every other payload here uses.
public struct UnjunkOpPayload: Codable, Sendable, Equatable {
    public var sourceMailboxId: Int64
    public var uidValidity: Int64
    public var uids: [UInt32]
    /// See `ArchiveOpPayload.relocatedMessageId`'s doc comment — identical
    /// role, just for `.unjunk`.
    public var relocatedMessageId: Int64?

    public init(sourceMailboxId: Int64, uidValidity: Int64, uids: [UInt32], relocatedMessageId: Int64? = nil) {
        self.sourceMailboxId = sourceMailboxId
        self.uidValidity = uidValidity
        self.uids = uids
        self.relocatedMessageId = relocatedMessageId
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
    /// 実機報告 (2026-08-16, Gmail アカウント)「特定の1通に対して削除・
    /// アーカイブ解除・未読化が完全無反応」の修正 (3): `MessageRemoval
    /// .commit`がこの op を積むのと同じ呼吸で、その `message` 行の主キー
    /// (`MessageRecord.id`) をここへ写しておく — `commit`はこの直後に
    /// 同じ行を仮 UID (`uid = -messageId`) へ移送することが多い
    /// (`relocationDestinationId`が `nil` を返した場合は直接ハード削除する
    /// ので移送しないこともある。どちらのケースでも埋めておいて無害)。
    ///
    /// `OpQueueProcessor`がこの op を `.staleDiscarded` (対象メールボックス
    /// の `uidValidity` がもう合わない) として破棄するとき、この主キーが
    /// あることで「移送先に取り残された仮 UID 行」を正確に一意特定して
    /// ハード削除できる — `uids`（移送**前**の実 UID）はその時点でもう
    /// どの行も指していない（行はとっくに `mailboxId`/`uid` を書き換えられ
    /// ている）ので、`sourceMailboxId`/`uids` だけでは逆引きできない。
    /// 詳細は `OpQueueProcessor.cleanUpOrphanedRelocation(for:db:)` 参照。
    ///
    /// 既存 (この変更前) にキューへ積まれた op の JSON にはこのキーが
    /// 無いので `nil` にデコードされる — `Optional` の自動 Codable 準拠が
    /// 欠損キーを `nil` として扱うため、マイグレーション無しで後方互換。
    /// `nil` のときは単に「掃除できるものが無い」として何もしない
    /// (旧 op のゴーストはこの経路では拾えないが、`ThreadQuery.deduplicate`
    /// のタイブレーク修正で表示・操作は妨げられない — DB に残るだけ)。
    public var relocatedMessageId: Int64?

    public init(sourceMailboxId: Int64, uidValidity: Int64, uids: [UInt32], relocatedMessageId: Int64? = nil) {
        self.sourceMailboxId = sourceMailboxId
        self.uidValidity = uidValidity
        self.uids = uids
        self.relocatedMessageId = relocatedMessageId
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
    /// See `ArchiveOpPayload.relocatedMessageId`'s doc comment — identical
    /// role, just for `.unarchive`.
    public var relocatedMessageId: Int64?

    public init(sourceMailboxId: Int64, uidValidity: Int64, uids: [UInt32], relocatedMessageId: Int64? = nil) {
        self.sourceMailboxId = sourceMailboxId
        self.uidValidity = uidValidity
        self.uids = uids
        self.relocatedMessageId = relocatedMessageId
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

/// `emptyTrash`'s payload — every UID `EmptyTrash.commit` removed locally
/// from `mailboxId` in one "ゴミ箱を空にする" action, applied as a single
/// `STORE`+`EXPUNGE` pair rather than the "one op per message" shape
/// `MessageRemoval.commit`'s callers use: an empty-trash action can remove
/// hundreds of messages at once, and one IMAP round trip per message (even
/// over the single connection `OpQueueProcessor.replayPass` already keeps
/// open for the whole batch) would make that painfully slow. Same
/// `uidValidity` staleness-check contract as every other payload here
/// (`SetFlagsOpPayload`'s doc comment): discarded
/// (`OpQueueProcessor.ApplyOutcome.staleDiscarded`) if `mailboxId`'s
/// current `uidValidity` no longer matches — the folder was recreated since
/// `EmptyTrash.commit` ran, so these UIDs may now name unrelated messages.
public struct EmptyTrashOpPayload: Codable, Sendable, Equatable {
    public var mailboxId: Int64
    public var uidValidity: Int64
    public var uids: [UInt32]

    public init(mailboxId: Int64, uidValidity: Int64, uids: [UInt32]) {
        self.mailboxId = mailboxId
        self.uidValidity = uidValidity
        self.uids = uids
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
        op: FlagOp = .replace,
        db: Database
    ) throws {
        guard !uids.isEmpty else { return }
        let payload = SetFlagsOpPayload(mailboxId: mailboxId, uidValidity: uidValidity, uids: uids, flagsRaw: flags.rawValue, op: op)
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
        relocatedMessageId: Int64? = nil,
        db: Database
    ) throws {
        guard !uids.isEmpty else { return }
        let payload = DeleteOpPayload(sourceMailboxId: sourceMailboxId, uidValidity: uidValidity, uids: uids, relocatedMessageId: relocatedMessageId)
        try enqueue(kind: .delete, accountId: accountId, payload: payload, db: db)
    }

    public static func enqueueJunk(
        accountId: String,
        sourceMailboxId: Int64,
        uidValidity: Int64,
        uids: [UInt32],
        relocatedMessageId: Int64? = nil,
        db: Database
    ) throws {
        guard !uids.isEmpty else { return }
        let payload = JunkOpPayload(sourceMailboxId: sourceMailboxId, uidValidity: uidValidity, uids: uids, relocatedMessageId: relocatedMessageId)
        try enqueue(kind: .junk, accountId: accountId, payload: payload, db: db)
    }

    public static func enqueueUnjunk(
        accountId: String,
        sourceMailboxId: Int64,
        uidValidity: Int64,
        uids: [UInt32],
        relocatedMessageId: Int64? = nil,
        db: Database
    ) throws {
        guard !uids.isEmpty else { return }
        let payload = UnjunkOpPayload(sourceMailboxId: sourceMailboxId, uidValidity: uidValidity, uids: uids, relocatedMessageId: relocatedMessageId)
        try enqueue(kind: .unjunk, accountId: accountId, payload: payload, db: db)
    }

    public static func enqueueArchive(
        accountId: String,
        sourceMailboxId: Int64,
        uidValidity: Int64,
        uids: [UInt32],
        relocatedMessageId: Int64? = nil,
        db: Database
    ) throws {
        guard !uids.isEmpty else { return }
        let payload = ArchiveOpPayload(sourceMailboxId: sourceMailboxId, uidValidity: uidValidity, uids: uids, relocatedMessageId: relocatedMessageId)
        try enqueue(kind: .archive, accountId: accountId, payload: payload, db: db)
    }

    public static func enqueueUnarchive(
        accountId: String,
        sourceMailboxId: Int64,
        uidValidity: Int64,
        uids: [UInt32],
        relocatedMessageId: Int64? = nil,
        db: Database
    ) throws {
        guard !uids.isEmpty else { return }
        let payload = UnarchiveOpPayload(sourceMailboxId: sourceMailboxId, uidValidity: uidValidity, uids: uids, relocatedMessageId: relocatedMessageId)
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

    public static func enqueueEmptyTrash(
        accountId: String,
        mailboxId: Int64,
        uidValidity: Int64,
        uids: [UInt32],
        db: Database
    ) throws {
        guard !uids.isEmpty else { return }
        let payload = EmptyTrashOpPayload(mailboxId: mailboxId, uidValidity: uidValidity, uids: uids)
        try enqueue(kind: .emptyTrash, accountId: accountId, payload: payload, db: db)
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

    // MARK: - Discard (ユーザーによる取り消し)

    /// 未送信の操作を1件、ユーザーの意思で取り消す — `opQueue`行を削除し、
    /// `send`op の場合はそれが指す`outboxMessage`行も一緒に消す。
    ///
    /// 第2の削除が要る理由は`FailedOperationsView`が元々インラインで持って
    /// いた説明と同じ: これが無いと、恒久失敗した送信は一覧から消えるのに
    /// `outboxMessage`行 (とそれを読むサイドバーの「送信待ち」件数) だけが
    /// 永久に残り、再送する`opQueue`行はもう存在しない — 何をしても解消
    /// できない「送信中のまま」状態になる。他の kind (`setFlags`/`move`/
    /// `delete`/`archive`…) は既に変更済みのローカル状態へ適用する内容を
    /// 記述しているだけで、後始末すべき副テーブルの行を持たない。
    /// `saveDraft`が指す`draftMessage`行も**消さない** — サーバー保存に
    /// 失敗しただけで下書き本体はローカルに残しておくべきものだから
    /// (元の`FailedOperationsView.discard(_:)`の挙動をそのまま維持)。
    ///
    /// 取り消しは「サーバーへの反映を諦める」だけで、ローカル側の状態
    /// (既読フラグ・移動済みの配置) は元に戻さない — 巻き戻すと、ユーザーが
    /// 見ている一覧が操作前の状態へ勝手に戻ってしまう。次回サーバーと
    /// 同期した時点でサーバー側の状態に収束する。
    @discardableResult
    public static func discard(opId: Int64, db: Database) throws -> Bool {
        guard let op = try OpQueueRecord.fetchOne(db, key: opId) else { return false }
        try deleteSideEffects(of: op, db: db)
        let deleted = try OpQueueRecord.deleteOne(db, key: opId)
        if deleted {
            opReflectLogger.notice("op discarded by user kind=\(op.kind, privacy: .public) accountId=\(op.accountId, privacy: .private) opId=\(opId)")
        }
        return deleted
    }

    /// `accountId`の未送信操作をまとめて取り消す (診断画面の「未送信の操作を
    /// すべて破棄」) — 1件ずつの`discard(opId:db:)`と全く同じ副作用処理を、
    /// 呼び出し側の1トランザクション内で全行に適用する。戻り値は削除した
    /// `opQueue`行数。
    ///
    /// `kind`を指定するとその種類だけに絞る (種類別内訳から「`setFlags`の
    /// 暴走分だけ捨てて送信は残す」ような選択的な取り消しができるように
    /// するため)。
    @discardableResult
    public static func discardAll(accountId: String, kind: OpQueueKind? = nil, db: Database) throws -> Int {
        var request = OpQueueRecord.filter(Column("accountId") == accountId)
        if let kind {
            request = request.filter(Column("kind") == kind.rawValue)
        }
        let ops = try request.fetchAll(db)
        guard !ops.isEmpty else { return 0 }
        for op in ops {
            try deleteSideEffects(of: op, db: db)
        }
        let deleted = try request.deleteAll(db)
        opReflectLogger.notice("ops discarded by user count=\(deleted) kind=\(kind?.rawValue ?? "all", privacy: .public) accountId=\(accountId, privacy: .private)")
        return deleted
    }

    /// `discard(opId:db:)`/`discardAll(accountId:kind:db:)`が共有する副テーブル
    /// の後始末 — 現状`send`op の`outboxMessage`だけ (理由は`discard(opId:db:)`
    /// のdoc comment)。
    private static func deleteSideEffects(of op: OpQueueRecord, db: Database) throws {
        guard op.kind == OpQueueKind.send.rawValue,
              let payload = try? JSONDecoder().decode(SendOpPayload.self, from: op.payload) else { return }
        _ = try OutboxMessageRecord.deleteOne(db, key: payload.outboxMessageId)
    }
}
