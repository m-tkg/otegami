import Foundation
import GRDB
import OtegamiStore

/// The local-DB half of the swipe/bulk archive and delete actions —
/// "commit the removal immediately, make undo itself fully reversible"
/// rather than delaying the write (see `commit(_:summary:accountId:db:)`'s
/// doc comment for the data-loss bug that design replaced). Pulled out of
/// `MessageListView` (the app target's SwiftUI view that used to own all of
/// this as private methods) into `SyncEngine` so it's exercisable by a
/// plain `AppDatabase.makeInMemory()` unit test — the app-target version had
/// **no** automated coverage of the undo path at all, which is exactly how
/// 実機報告「アーカイブ後に元に戻すが効かない」shipped: `undo(_:db:)` re-inserted a
/// thread's messages *before* re-inserting the thread row itself whenever
/// the removal had emptied (and so deleted) that thread — i.e. every
/// single-message thread, the common case — which trips
/// `message.threadId`'s foreign-key constraint (`AppDatabase`'s
/// `foreignKeysEnabled = true`) and rolls back the whole restore. The
/// surrounding `catch` swallowed that failure silently, so "元に戻す" looked
/// like it did nothing. Fixed here by restoring the thread row first.
public enum MessageRemoval {
    /// Task #163 (実機フィードバック「ピン留めされたメールはアーカイブできない
    /// ようにしてほしい」): thrown by `commit(.archive, ...)` instead of
    /// running at all when `summary.thread.isPinned` is `true` — kept as a
    /// thrown error rather than folded into `commit`'s existing `nil`
    /// "nothing to remove" return so every call site (single swipe, the
    /// thread-detail toolbar, the accordion, the account-digest bulk swipe)
    /// can tell "blocked because pinned" apart from "already archived"/
    /// "already gone" and show the right message instead of silently
    /// no-op'ing. Only `.archive` is guarded — delete/junk/unarchive and
    /// every non-removal action (read state, pin toggle, move) are
    /// unaffected, matching the feature's scope.
    public enum ArchiveGuardError: Error, Equatable, Sendable {
        case pinned
    }

    public enum Kind: Sendable {
        case archive
        case delete
        /// D8「迷惑メールにする」— mirrors `.archive`'s shape exactly, just
        /// moving to the account's Junk-role mailbox at replay time
        /// (`OpQueue.enqueueJunk`, resolved/self-healed by
        /// `OpQueueProcessor.resolveOrCreateJunkMailbox` the same way
        /// `.delete` resolves Trash) rather than a pre-resolved local
        /// Archive mailbox id.
        case junk
        /// 「迷惑メール解除」— the junk view's swipe/context-menu reverse
        /// action, mirroring `.unarchive`'s shape exactly (see its doc
        /// comment): only the enqueued `OpQueueKind` (`.unjunk`) and the
        /// per-message "is this actually sitting in Junk?" guard differ.
        /// The relocation destination is the account's INBOX-role mailbox,
        /// the same one `.unarchive` restores into.
        case unjunk
        /// Task #87 (1): "アーカイブ解除" — the archive view's swipe/context-
        /// menu reverse action. Mirrors `.archive`'s local-commit shape
        /// exactly (remove the message's row from wherever it currently
        /// sits, enqueue the reverse op, let the destination side's own
        /// sync discover it later — see `commit(_:summary:accountId:db:)`'s
        /// doc comment for why every `Kind` here works this way rather than
        /// inserting a new row up front) — only the enqueued `OpQueueKind`
        /// (`.unarchive` instead of `.archive`) and the per-message
        /// "already in the right place?" guard differ.
        case unarchive
    }

    /// Everything `undo(_:db:)` needs to reverse one `commit(_:summary:
    /// accountId:db:)` call: the thread's aggregate row and every message
    /// row it actually removed (captured *before* removal, full field
    /// data — re-inserting them restores the exact same `id`s, so nothing
    /// else in the app needs to know a delete/archive was ever reversed),
    /// plus the opQueue row ids that call enqueued (captured via a
    /// before/after max-`id` diff within the same transaction —
    /// `OpQueue.enqueueDelete`/`enqueueArchive` don't themselves return the
    /// id they just inserted).
    public struct Snapshot: Sendable {
        public var thread: ThreadRecord
        public var messages: [MessageRecord]
        public var opQueueIds: [Int64]

        public init(thread: ThreadRecord, messages: [MessageRecord], opQueueIds: [Int64]) {
            self.thread = thread
            self.messages = messages
            self.opQueueIds = opQueueIds
        }
    }

    /// Removes every message `ThreadQuery.actionTargets(for:db:)` returns
    /// for `summary` from its current mailbox and enqueues one archive/
    /// delete op per message — the destination (or, for a Gmail archive,
    /// "no destination — just unlabel") is resolved by `OpQueueProcessor`
    /// at *replay* time, not here at enqueue time (see `OpQueueKind
    /// .archive`'s doc comment for why a pre-resolved local Archive-role
    /// mailbox lookup used to make archiving silently do nothing on a real
    /// Gmail account).
    ///
    /// Commits the local database write (and enqueues the op) *immediately*
    /// — this feature's first version instead delayed the local write
    /// itself so "undo" could just... not commit it, which turned out to
    /// have a real data-loss bug (caught by `scripts/verify-ios-m3.sh`'s
    /// offline swipe-delete phase: an app relaunch inside the old
    /// delayed-commit window silently lost the action, since the pending
    /// `Task.sleep` driving the eventual write died with the process
    /// before ever running). Committing immediately (durable to disk
    /// before this method even returns) and instead making *undo itself*
    /// fully reversible closes that gap: the opQueue row this enqueues
    /// survives any kill regardless of timing, and a normal relaunch's
    /// existing foreground-sync replay picks it up exactly like any other
    /// queued op.
    ///
    /// An archive target already sitting in the account's Archive-role
    /// mailbox — or, on Gmail, in All Mail, which is where "archived" lives
    /// there — (re-archiving an already-archived thread) is skipped rather
    /// than deleted — only messages this call actually removes end up in
    /// the returned `Snapshot.messages`, so `undo(_:db:)` never tries to
    /// re-insert a row that was never deleted in the first place (that
    /// used to be a second, narrower silent-rollback path: re-inserting a
    /// still-present row trips its primary-key uniqueness the same way the
    /// thread-ordering bug trips the `threadId` foreign key).
    /// - Parameter markSeenOnArchive: 設定「アーカイブ時に既読にする」
    ///   (`ArchiveActionSettingsStore`) — `kind == .archive` のときだけ意味を
    ///   持つ (`.delete`/`.junk`/`.unarchive`には影響しない)。`true` の場合、
    ///   各 target message を `OpQueue.enqueueArchive` する**前**に
    ///   `MessageReadMarker.markSeen(messageId:accountId:db:)` を呼ぶ —
    ///   `OpQueueProcessor` は opQueue を id 順に実行するため、flag STORE
    ///   op が archive (move) op より後に積まれると、移動済み UID への
    ///   STORE になり失敗する。デフォルト `false` (既存呼び出しは全て
    ///   従来どおり既読状態を変えない)。
    @discardableResult
    public static func commit(_ kind: Kind, summary: ThreadSummary, accountId: String, db: Database, markSeenOnArchive: Bool = false) throws -> Snapshot? {
        guard let threadId = summary.thread.id else { return nil }
        // Task #163: `summary.thread.isPinned` is the exact same OR-
        // aggregate `ThreadRecord` column every list/detail screen already
        // displays pin state from (`ThreadRecord.isPinned`'s doc comment —
        // "at least one message in the thread has `isPinnedLocal` set"),
        // whether or not server-flag sync (`\Flagged`) is enabled — that
        // column is the local pin source of truth either way, so this guard
        // can never disagree with what the pin icon on screen shows.
        if kind == .archive, summary.thread.isPinned {
            throw ArchiveGuardError.pinned
        }
        guard let thread = try ThreadRecord.fetchOne(db, key: threadId) else { return nil }
        let targets = try ThreadQuery.actionTargets(for: summary, db: db)
        let beforeMaxOpId = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM opQueue") ?? 0
        // Both `.archive`'s and `.unarchive`'s per-message guards need this,
        // and so does `relocationDestinationId` (Gmail's "archived" location
        // is All Mail, not a dedicated Archive-role mailbox — see below) —
        // fetched once rather than per-message since it's the same account
        // for every target here.
        let account = try AccountRecord.fetchOne(db, key: accountId)
        let accountKind = account?.kind
        // Task #120 (実機報告「アーカイブ解除しても受信箱に pull-to-refresh まで
        // 現れない」): resolved once per commit call, not per-message — the
        // mailbox this `kind` relocates a removed message *into* locally,
        // right now, so it's visible in that mailbox's own list without
        // waiting for that mailbox's own next sync to discover it. `nil`
        // when no such mailbox is known locally yet (this account's very
        // first archive/junk/delete before that role's mailbox has ever
        // been discovered, or a Gmail archive — see `destinationMailbox`'s
        // doc comment) — falls back to the pre-#120 behavior for that
        // message: remove locally, let the destination's own eventual sync
        // discover it, exactly as before this task.
        let destination = try Self.destinationMailbox(for: kind, account: account, db: db)
        var removedMessages: [MessageRecord] = []
        for message in targets {
            guard let messageId = message.id else { continue }
            guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { continue }
            // 実機報告 (2026-08-16, Gmail アカウント)「特定の1通に対して
            // 削除・アーカイブ解除・未読化が完全無反応 (エラー表示も無し)」
            // の根本原因の一つ: `message` 自身が既に
            // `MessageRecord.isPendingRelocation` (`uid <= 0`) — 直前の
            // 別操作がまだサーバー確認待ちで移送中の行 (`EnvelopePersister
            // .reconcilePendingRelocation` が本物の UID に昇格させる前)、
            // あるいは R3 (`messageId` が nil/空で永久に昇格できない) や
            // staleDiscarded (元の op が破棄され二度と昇格しない) で恒久的に
            // 取り残されたゴースト行のどちらか — には送る先の本物 UID が
            // 無い。以前はこの行全体を `guard let uid = UInt32(exactly:
            // message.uid) else { continue }` で丸ごと skip していたため、
            // サーバー op は積まれない (これは正しい) が**ローカルの移送/
            // 削除も一切実行されない**まま `removedMessages` に積まれず、
            // `commit` は `nil` を返し、呼び出し元の UI は何のエラーも出さず
            // 完全に無反応になっていた (`ThreadQuery.deduplicate` の tie-break
            // 修正と合わせて読むこと — dedup がゴーストを本物より優先して
            // 代表行に選んでいたことで、ユーザーが実際に操作するのが常に
            // このゴースト行だった、というのがこの実機報告の実態)。
            //
            // 修正: `isGhostTarget` はサーバー op の enqueue だけを止める。
            // 各 `Kind` ごとの位置ガード (`isAlreadyArchived`/`isArchived`/
            // `mailbox.role == .junk`) はゴースト行にもそのまま適用する —
            // ゴーストの `mailboxId` は直前の移送でどこに置かれたかを正しく
            // 表しているため、実在行と同じ意味を持つ。ガードを通過したら、
            // ループ末尾のローカル移送/ハード削除は無条件に実行する。サー
            // バー側は元の移送 op (まだ `opQueue` に生きていれば) の通常の
            // replay と、それに続く同期の自己修復に任せる。
            let isGhostTarget = message.isPendingRelocation
            // 設定「アーカイブ時に既読にする」で `markSeen` した場合、
            // relocation (下の`if let destinationId ...`分岐) にはループ
            // 変数 `message` (markSeen 前の stale コピー) ではなく DB から
            // 取り直した最新コピーを使う — さもないと relocation の
            // `update` が既読フラグを巻き戻してしまう。一方 `removedMessages`
            // (undo 用スナップショット) には意図的に markSeen **前**の
            // 元コピー (`message`) を積む: undo は未読状態まで含めて元通り
            // 復元し、`opQueueIds` の捕捉範囲 (`beforeMaxOpId` より後) には
            // markSeen が積んだ flag op も含まれるので undo で一緒に
            // キャンセルされる、という一貫した設計にするため。
            var messageForRelocation = message
            switch kind {
            case .archive:
                // The exact mirror image of `.unarchive`'s own guard below:
                // a message already sitting in an "archived" location has
                // nothing left to archive. Gmail has no Archive-role mailbox
                // at all, so All Mail is that location there — without this
                // second half, archiving a row already in All Mail would
                // enqueue `\Deleted`+`EXPUNGE` *against All Mail*, which on
                // Gmail is a real delete (moves it to Trash), not an unlabel.
                // Unreachable from a swipe (`MessageListView
                // .refreshArchiveViewFlag` swaps it for アーカイブ解除 in that
                // view) but reachable from bulk selection, the notification
                // action and the thread-detail toolbar.
                let isAlreadyArchived = mailbox.role == .archive || (mailbox.role == .all && accountKind == .gmail)
                guard !isAlreadyArchived else { continue }
                if !isGhostTarget {
                    guard let uid = UInt32(exactly: message.uid) else { continue }
                    if markSeenOnArchive {
                        // OpQueueProcessor は opQueue を id 順に実行するため、
                        // この flag STORE op は直後の archive (move) op より
                        // 必ず先に enqueue する — 逆順だと移動済み UID への
                        // STORE になり失敗する。
                        if try MessageReadMarker.markSeen(messageId: messageId, accountId: accountId, db: db),
                           let refetched = try MessageRecord.fetchOne(db, key: messageId) {
                            messageForRelocation = refetched
                        }
                    }
                    try OpQueue.enqueueArchive(
                        accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [uid], relocatedMessageId: messageId, db: db
                    )
                }
            case .delete:
                if !isGhostTarget {
                    guard let uid = UInt32(exactly: message.uid) else { continue }
                    try OpQueue.enqueueDelete(
                        accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [uid], relocatedMessageId: messageId, db: db
                    )
                }
            case .junk:
                if !isGhostTarget {
                    guard let uid = UInt32(exactly: message.uid) else { continue }
                    try OpQueue.enqueueJunk(
                        accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [uid], relocatedMessageId: messageId, db: db
                    )
                }
            case .unjunk:
                // The mirror image of `.junk`: only a message actually
                // sitting in this account's Junk-role mailbox has anything
                // to reverse. Unreachable from a junk-view swipe with a
                // non-junk row (`MessageListView.refreshJunkViewFlag` only
                // swaps the slot inside a junk view), but reachable from
                // bulk selection and the thread-detail toolbar on a thread
                // whose messages are only partly in Junk.
                guard mailbox.role == .junk else { continue }
                if !isGhostTarget {
                    guard let uid = UInt32(exactly: message.uid) else { continue }
                    try OpQueue.enqueueUnjunk(
                        accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [uid], relocatedMessageId: messageId, db: db
                    )
                }
            case .unarchive:
                // The mirror image of `.archive`'s own guard just above:
                // only a message actually sitting in an "archived" location
                // (a real Archive-role mailbox, or — for Gmail, which has
                // no such role at all — All Mail) has anything to reverse.
                let isArchived = mailbox.role == .archive || (mailbox.role == .all && accountKind == .gmail)
                guard isArchived else { continue }
                if !isGhostTarget {
                    guard let uid = UInt32(exactly: message.uid) else { continue }
                    try OpQueue.enqueueUnarchive(
                        accountId: accountId, sourceMailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [uid], relocatedMessageId: messageId, db: db
                    )
                }
            }
            let relocationTargetId = try Self.relocationDestinationId(
                kind: kind, accountKind: accountKind, message: messageForRelocation,
                destination: destination, db: db
            )
            if let destinationId = relocationTargetId, destinationId != message.mailboxId {
                // Relocate in place rather than delete-then-wait-for-sync:
                // same row `id` (so its thread assignment, cached body/
                // attachments, and translation state all carry over
                // untouched), moved to the destination mailbox with a
                // synthetic placeholder UID (`MessageRecord
                // .isPendingRelocation`'s doc comment) until
                // `AccountSyncer.reconcilePendingRelocation` adopts the real
                // one. The `messageSearchIndex`/FTS row is untouched too —
                // relocating changes *where* the message lives, never its
                // content, so there's nothing to delete or reindex here
                // (contrast the `else` branch below, a true removal).
                var relocated = messageForRelocation
                relocated.mailboxId = destinationId
                relocated.uid = -messageId
                relocated.updatedAt = Date()
                try relocated.update(db)
            } else {
                // No destination known locally yet (or a Gmail archive whose
                // All Mail copy is already here / can't be reconciled later —
                // see `relocationDestinationId`'s doc comment): the pre-#120
                // behavior. M7: `messageSearchIndex`
                // isn't a real foreign-keyed table, so this removal needs
                // its own explicit index cleanup alongside the `message`
                // row's.
                try FTSIndexer.delete(messageId: messageId, db: db)
                try MessageRecord.deleteOne(db, key: messageId)
            }
            removedMessages.append(message)
        }
        guard !removedMessages.isEmpty else { return nil }
        try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        let opQueueIds = try Int64.fetchAll(db, sql: "SELECT id FROM opQueue WHERE id > ? ORDER BY id", arguments: [beforeMaxOpId])
        return Snapshot(thread: thread, messages: removedMessages, opQueueIds: opQueueIds)
    }

    /// Task #120: the mailbox `kind` relocates a message into locally, or
    /// `nil` when there's nothing safe/known to relocate into yet (the
    /// caller then falls back to the pre-#120 remove-and-wait-for-sync
    /// behavior for that message):
    /// - `.unarchive`/`.unjunk` → this account's INBOX-role mailbox. Always known
    ///   locally once an account has completed even one sync (mirrors
    ///   `OpQueueProcessor.inboxMailbox`'s own "never `nil` in practice"
    ///   assumption).
    /// - `.junk`/`.delete` → this account's Junk-/Trash-role mailbox, if
    ///   already discovered. `nil` for an account that's never junked/
    ///   deleted anything before and whose server doesn't advertise one —
    ///   `OpQueueProcessor.resolveOrCreateJunkMailbox`/
    ///   `resolveOrCreateTrashMailbox` will still `CREATE` one server-side
    ///   on replay; this method just can't relocate into a mailbox this
    ///   database doesn't have a row for yet.
    /// - `.archive` → this account's Archive-role mailbox — *except* on
    ///   Gmail, which has no dedicated Archive folder at all
    ///   (`OpQueueKind.archive`'s doc comment): "archiving" there just
    ///   un-labels the source, and the message's All Mail copy (role `.all`)
    ///   is what represents it in the "アーカイブ" unified category, so All
    ///   Mail is the destination. Whether a Gmail archive may actually
    ///   relocate *into* it is decided per-message by
    ///   `relocationDestinationId` — All Mail may already hold a real row for
    ///   the same message, and a second synthetic one would sit beside it as
    ///   a visible duplicate.
    private static func destinationMailbox(for kind: Kind, account: AccountRecord?, db: Database) throws -> MailboxRecord? {
        guard let account else { return nil }
        let role: MailboxRoleRecord
        switch kind {
        case .unarchive, .unjunk: role = .inbox
        case .junk: role = .junk
        case .delete: role = .trash
        case .archive: role = account.kind == .gmail ? .all : .archive
        }
        return try MailboxRecord
            .filter(Column("accountId") == account.id)
            .filter(Column("role") == role.rawValue)
            .fetchOne(db)
    }

    /// The per-message final say over `destinationMailbox`'s per-call answer,
    /// and a no-op (`destination`'s own id, unchanged) for everything except
    /// a Gmail `.archive`.
    ///
    /// 実機報告「iOS で Gmail のさっき受信したメールをアーカイブしたらどこにも
    /// 表示されなくなった」: a Gmail archive used to always delete the source
    /// row outright, on the assumption that All Mail already independently
    /// held the same message. That assumption only holds for messages already
    /// inside All Mail's locally-synced window — All Mail is never part of
    /// `SyncScope.inboxOnly` (which is what launch/foreground/push/IDLE all
    /// use), so a message that arrived *after* the account's initial sync has
    /// no All Mail row at all yet. Deleting the INBOX row then removed the
    /// last trace of it from the database: gone from 受信トレイ, absent from
    /// both アーカイブ views, and — since Gmail's archive replay reports no
    /// affected mailbox to resync — nothing scheduled to bring it back.
    ///
    /// So: relocate into All Mail (the same synthetic-placeholder-UID
    /// mechanism every non-Gmail archive already uses) whenever doing so
    /// can't produce a duplicate, and only fall back to the old delete when
    /// it could:
    /// - A row for this same message already sits in All Mail → delete. The
    ///   grouped list, thread detail and thread aggregates all dedup by
    ///   message identity, but `ThreadQuery.flatSummaries`/
    ///   `unifiedInboxFlatSummaries` (フラット表示) deliberately don't, so a
    ///   second row there would be visible. Identity is judged the same way
    ///   `ThreadQuery.identityKey` judges it: `gmailMessageId` (`X-GM-MSGID`,
    ///   account-unique and Gmail-issued) when present, else the RFC 822
    ///   `Message-ID`.
    /// - No RFC 822 `Message-ID` on the row → delete.
    ///   `EnvelopePersister.reconcilePendingRelocation` matches placeholders
    ///   by that header alone, so a placeholder without one would never be
    ///   adopted onto its real UID and would instead linger forever beside
    ///   the real row once All Mail syncs. Vanishingly rare for Gmail-hosted
    ///   mail; `docs/design-system.md` records it as a known limitation.
    private static func relocationDestinationId(
        kind: Kind, accountKind: AccountKind?, message: MessageRecord,
        destination: MailboxRecord?, db: Database
    ) throws -> Int64? {
        guard let destinationId = destination?.id else { return nil }
        guard kind == .archive, accountKind == .gmail else { return destinationId }
        guard let rfcMessageId = message.messageId, !rfcMessageId.isEmpty else { return nil }
        let identityFilter: SQLExpression
        if let gmailMessageId = message.gmailMessageId {
            identityFilter = Column("gmailMessageId") == gmailMessageId
        } else {
            identityFilter = Column("messageId") == rfcMessageId
        }
        let alreadyInAllMail = try MessageRecord
            .filter(Column("mailboxId") == destinationId)
            .filter(identityFilter)
            .fetchCount(db) > 0
        return alreadyInAllMail ? nil : destinationId
    }

    /// Reverses one `commit(_:summary:accountId:db:)` call: deletes the
    /// opQueue rows it enqueued (a no-op for any that already replayed —
    /// `MessageListView.scheduleUndo`'s doc comment covers that race: if
    /// the account's IDLE loop or a manual refresh replayed the op
    /// independently before the undo window elapsed, this deletion is
    /// simply a no-op and only the local restore below applies — a rare,
    /// accepted edge case, not silent data corruption either way) and
    /// re-inserts the thread aggregate row (if `commit` deleted it — i.e.
    /// this was the thread's last remaining message) *before* re-inserting
    /// any removed message.
    ///
    /// Task #120: `commit` no longer always deletes a target message row —
    /// when it knew a destination mailbox locally, it *relocated* the row
    /// there instead (`MessageRecord.isPendingRelocation`), leaving it very
    /// much still present. Each `snapshot.messages` entry is handled
    /// according to which actually happened, decided by whether a row with
    /// that `id` still exists:
    /// - **Still exists (relocated)**: restore only `mailboxId`/`uid` back
    ///   to their pre-commit values via `update`, not a blanket overwrite of
    ///   every column — any *other* field the row picked up during the
    ///   pending window (e.g. its body finished fetching, or a read/unread
    ///   toggle) is intentionally left alone rather than silently reverted
    ///   by an unrelated "元に戻す" tap. A no-op if `mailboxId`/`uid` already
    ///   match (e.g. this message's slot in `snapshot.messages` belongs to
    ///   a `kind` that never relocated it in the first place — every entry
    ///   here that *was* relocated has both fields differ from the
    ///   snapshot's captured pre-commit values, by construction).
    /// - **Gone (deleted)**: `insert` with the original id, exactly as
    ///   before this task (GRDB's default `insert` includes an already-set
    ///   primary key value in the `INSERT` statement, and the row it
    ///   occupied was just deleted, so there's no conflict to resolve), and
    ///   `FTSIndexer.reindex` restores its search-index row the same way
    ///   `FTSIndexer.delete` removed it (relocated rows never had their FTS
    ///   row touched in the first place — see `commit`'s doc comment — so
    ///   there's nothing to reindex for those).
    ///
    /// The thread-before-messages order is load-bearing for the delete/
    /// insert case: `message.threadId` has a foreign key to `thread`
    /// (`AppDatabase.foreignKeysEnabled = true`), so inserting a message
    /// that still points at a thread row that hasn't been restored yet
    /// throws immediately and rolls back the *entire* transaction —
    /// restoring nothing at all. This was the root cause behind 実機報告
    /// 「アーカイブ後に元に戻すが効かない」: a thread's last message being
    /// archived/deleted empties (and so deletes) the thread row, and the
    /// previous ordering inserted messages first. A relocated (never
    /// deleted) message never hits this at all — its thread row was never
    /// removed, since the message row itself never left the `message`
    /// table.
    ///
    /// Every write here still throws normally (no `try?`), matching every
    /// other opQueue-enqueuing/db-mutating path in this file: a failure
    /// just leaves the delete/archive/relocation applied, same as if
    /// "元に戻す" had never been tapped.
    ///
    /// Task #183: the "still exists (relocated)" branch above no longer
    /// blindly writes `original`'s `(mailboxId, uid)` back onto the row —
    /// see the guard inside the loop below and `MessageRelocationConflict`
    /// for why a different row can already occupy that slot by the time
    /// undo runs, and how that's resolved without tripping `message`'s
    /// `(mailboxId, uid)` uniqueness constraint.
    public static func undo(_ snapshot: Snapshot, db: Database) throws {
        try OpQueueRecord.deleteAll(db, keys: snapshot.opQueueIds)
        guard let threadId = snapshot.thread.id else { return }
        let threadStillExists = try ThreadRecord.fetchOne(db, key: threadId) != nil
        if !threadStillExists {
            var restoredThread = snapshot.thread
            try restoredThread.insert(db)
        }
        var extraAffectedThreadIds: Set<Int64> = []
        for original in snapshot.messages {
            guard let messageId = original.id else { continue }
            if var current = try MessageRecord.fetchOne(db, key: messageId) {
                guard current.mailboxId != original.mailboxId || current.uid != original.uid else { continue }
                // Task #183: guard the destination `(mailboxId, uid)` slot
                // the same way `AccountSyncer.reconcilePendingRelocation`/
                // `AccountDuplicateMerger.mergeCollidingMailbox` do, rather
                // than blindly writing back `original`'s pre-commit
                // position — a *different* row can have genuinely landed
                // there since (most plausibly the mailbox's `uidValidity`
                // reset and a full resync placed an unrelated message at
                // this same `uid`) while this row sat relocated elsewhere.
                // If so, this restore can't recreate the original slot
                // without colliding: fold this row's local-only state
                // forward into whatever's occupying it and discard this
                // row instead of crashing (same accepted trade-off
                // `MessageRelocationConflict` already documents).
                if var occupant = try MessageRecord
                    .filter(Column("mailboxId") == original.mailboxId)
                    .filter(Column("uid") == original.uid)
                    .fetchOne(db), occupant.id != messageId {
                    extraAffectedThreadIds.formUnion(
                        try MessageRelocationConflict.mergeAndDiscard(mover: current, into: &occupant, db: db)
                    )
                    continue
                }
                current.mailboxId = original.mailboxId
                current.uid = original.uid
                current.updatedAt = Date()
                try current.update(db)
            } else {
                var restored = original
                try restored.insert(db)
                try FTSIndexer.reindex(messageId: messageId, db: db)
            }
        }
        if threadStillExists {
            try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        }
        for extraThreadId in extraAffectedThreadIds where extraThreadId != threadId {
            try ThreadAssigner.recomputeAggregates(threadId: extraThreadId, db: db)
        }
    }
}
