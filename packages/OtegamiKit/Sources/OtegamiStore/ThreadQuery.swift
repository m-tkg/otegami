import Foundation
import GRDB
import OtegamiCore

/// One thread plus its most recent message's display-relevant fields —
/// what `ThreadRow` (M4's per-thread message-list row: participants,
/// subject, snippet, count badge, unread dot, latest date) needs without a
/// separate query per row. `ThreadRecord` alone only has
/// `messageCount`/`unreadCount`/`lastMessageDate`/`normalizedSubject`; the
/// sender/snippet/original (non-normalized) subject only exist per-message.
public struct ThreadSummary: Sendable, Equatable, Identifiable {
    public var thread: ThreadRecord
    /// The newest message in the thread (by `internalDate`, tie-broken by
    /// `uid`). `nil` only transiently — a thread with zero messages is
    /// deleted by `ThreadAssigner.recomputeAggregates`, so this shouldn't
    /// normally be `nil` for a thread a query actually returned.
    public var latestMessage: MessageRecord?

    /// B3 フラット表示: non-`nil` only for a synthetic, single-message
    /// "thread" built by `flatSummaries`/`unifiedInboxFlatSummaries` below —
    /// see `init(flatMessage:accountId:)`. Distinct from `thread.id`
    /// because flat mode can legitimately show *several* rows sharing the
    /// same real `thread.id` (every message of a multi-message thread gets
    /// its own row), and `List`/`ForEach` identity requires each row's `id`
    /// to be unique — `thread.id` alone would collide across those rows.
    private var flatMessageId: Int64?

    public var id: Int64 { flatMessageId ?? (thread.id ?? 0) }

    /// 実機フィードバック第3弾 (A): public accessor for `flatMessageId` — the
    /// tapped message's own id when this summary is a flat-mode "thread of
    /// one" row, `nil` for a real (possibly multi-message) threaded-mode
    /// row. Callers use this to decide whether opening this row's detail
    /// screen should show only this one message (flat mode's expectation —
    /// see `MessageListView`'s doc comment) or the full accordion thread.
    public var singleMessageId: Int64? { flatMessageId }

    /// Task #151 (「アーカイブ済みの可視化」): whether this thread (grouped
    /// mode) or this single message (flat mode, `singleMessageId != nil`)
    /// has at least one message in a mailbox that counts as "archived" —
    /// see `GmailArchiveFilter.messageIsArchivedSQL`'s doc comment for the
    /// exact per-mailbox predicate (non-Gmail `role == .archive`; Gmail
    /// All Mail membership minus INBOX/Sent/Drafts duplicates). Defaults to
    /// `false` here so every existing call site keeps compiling; the real
    /// query call sites in this file (and `SearchQuery`) explicitly compute
    /// and set it after construction — see `ThreadQuery.isThreadArchived`/
    /// `isMessageArchived`.
    public var isArchived: Bool = false

    public init(thread: ThreadRecord, latestMessage: MessageRecord?) {
        self.thread = thread
        self.latestMessage = latestMessage
        self.flatMessageId = nil
    }

    /// B3: wraps one message as a "thread of one" for flat-mode row
    /// rendering — `ThreadRowView`/`MessageListRow` read only `summary
    /// .thread.*`/`summary.latestMessage`/`summary.id`, so this needs no
    /// changes to either: `thread.messageCount = 1` keeps the ">1" count
    /// badge from appearing, `thread.unreadCount`/`isPinned` reflect this
    /// one message directly rather than a real aggregate, and `thread.id`
    /// is still the message's *real* `threadId` — swipe/tap actions
    /// (toggleRead/archive/delete/pin) deliberately keep operating on the
    /// whole underlying thread even from a flat row (see
    /// `MessageListView`'s flat-mode doc comment for why this was chosen
    /// over building a fully separate per-message action path).
    public init(flatMessage message: MessageRecord, accountId: String) {
        self.thread = ThreadRecord(
            id: message.threadId,
            accountId: accountId,
            normalizedSubject: message.normalizedSubject,
            lastMessageDate: message.date ?? message.internalDate,
            messageCount: 1,
            unreadCount: message.flags.contains(.seen) ? 0 : 1,
            isPinned: message.isPinnedLocal
        )
        self.latestMessage = message
        self.flatMessageId = message.id
    }
}

/// Query helpers for `ThreadRecord`/`ThreadSummary`, the M4 counterparts to
/// `MessageQuery`/`MailboxQuery`. `MessageListView` observes these instead
/// of raw `MessageRecord` rows once a mailbox has been threaded.
public enum ThreadQuery {
    /// Threads with at least one message in `mailboxId`, newest first.
    /// `thread.lastMessageDate` reflects the thread's newest message
    /// account-wide (a thread can span mailboxes, e.g. Inbox + Sent), which
    /// is also what this sorts by — matching how a label-based mail client
    /// like Gmail orders a folder's thread list.
    ///
    /// M10 rewrite (docs/performance.md): the original `SELECT DISTINCT
    /// thread.* ... JOIN message ...` had to join and de-duplicate every
    /// matching *message* row before it could sort/limit — at 100k-message
    /// scale that meant sorting effectively the whole mailbox even for a
    /// 50-row first page. An `EXISTS` membership check instead lets SQLite
    /// walk `thread` directly in `lastMessageDate` order (via
    /// `thread_on_lastMessageDate`, added in v9) and stop as soon as
    /// `limit` threads have passed the check — the per-thread `EXISTS`
    /// probe itself is an index lookup against `message_on_threadId_mailboxId`
    /// (also v9), not a scan. `limit` is `nil` (unlimited, matching the
    /// pre-M10 behavior) unless the caller opts into paging.
    /// 未読のみ表示 (ヘッダのトグル、`MailScreenView`/`MessageListView`, iOS
    /// のみ): `unreadOnly` true で `thread.unreadCount > 0` を追加する — 個々の
    /// メッセージの `flagsRaw` ではなく `ThreadAssigner.recomputeAggregates`
    /// が維持する集計列を見るのは、ピン留め (`thread.isPinned`) と同じ理由:
    /// 集計済みの列を見ればスレッド単位のフィルタにジョインが要らない。
    /// Task #52 追記: `mailboxId`が Gmail アカウントの All Mail (role `.all`)
    /// なら、`GmailArchiveFilter`の「アーカイブ」定義 (INBOX/Sent/Draftsとの
    /// 重複を除外) を常に適用する — All Mail をどの導線 (カテゴリ優先メニュー
    /// の「アーカイブ」行/アカウント優先メニューの素のフォルダツリー/検索) から
    /// 開いても同じ「アーカイブ済み」集合を見せる、という単一の定義に統一する
    /// ための判断 (`docs/design-system.md`参照)。Gmail の All Mail 以外の
    /// どのメールボックスにも影響しない (フィルタ自身のガード節による)。
    /// Task #142 追記 (「フラグ付きのみ表示」): `pinnedOnly` true で
    /// `thread.isPinned = 1` を追加する — `unreadOnly`が読む`thread
    /// .unreadCount`と同じ「集計済みの列を見ればスレッド単位のフィルタに
    /// ジョインが要らない」理由で、こちらもスレッドの OR-aggregate
    /// (`ThreadRecord.isPinned`、ローカルピン+`\Flagged`同期の両方を反映
    /// 済み — `docs/design-system.md`の Task #142 節参照) をそのまま見る。
    public static func request(mailboxId: Int64, limit: Int? = nil, unreadOnly: Bool = false, pinnedOnly: Bool = false) -> SQLRequest<ThreadRecord> {
        var sql = """
            SELECT thread.* FROM thread
            WHERE EXISTS (
                SELECT 1 FROM message
                JOIN mailbox ON mailbox.id = message.mailboxId
                JOIN account ON account.id = mailbox.accountId
                WHERE message.threadId = thread.id AND message.mailboxId = ?
                      AND \(GmailArchiveFilter.excludeUnarchivedSQL)
            )
            """
        var arguments: [(any DatabaseValueConvertible)?] = [mailboxId]
        if unreadOnly {
            sql += " AND thread.unreadCount > 0"
        }
        if pinnedOnly {
            sql += " AND thread.isPinned = 1"
        }
        sql += " ORDER BY thread.isPinned DESC, thread.lastMessageDate DESC, thread.id DESC"
        if let limit {
            sql += " LIMIT ?"
            arguments.append(limit)
        }
        return SQLRequest(sql: sql, arguments: StatementArguments(arguments))
    }

    /// Threads with at least one message in a `role`-role mailbox across
    /// any of `accountIds` — the "すべての受信トレイ" unified inbox
    /// (`role == .inbox`, the default), and 画面構造改修バッチ (Task #33, 3)
    /// のカテゴリ優先メニューが追加した「横断ビュー」(他の role) の両方が
    /// これを使う。Each thread still belongs to exactly one account
    /// (`thread.accountId`); this unions across accounts at query time
    /// rather than merging threads across account boundaries (plan: "アカウ
    /// ント境界を跨いだスレッド結合はしない"). Same `EXISTS`-based rewrite as
    /// ``request(mailboxId:limit:)`` and for the same reason — see its doc
    /// comment. `mailbox.isHidden = 0` excludes hidden mailboxes (メール
    /// ボックス単位の非表示) from the aggregate — see `MailboxRecord
    /// .isHidden`'s doc comment. `unreadOnly` — see `request(mailboxId:
    /// limit:unreadOnly:)`'s doc comment.
    /// `account.kind`をJOINして参照するのは Gmail のアーカイブマッピング
    /// (`MailboxRoleRecord.gmailArchiveQueryRole`) のため — Gmail アカウント
    /// だけ`role`の代わりに`role.gmailArchiveQueryRole`(`.archive`→`.all`、
    /// 他は恒等)を見る (Task #52, 2)。
    ///
    /// Task #141 追記 (「すべてのメール」): `role == .all`のときだけ、
    /// 非Gmailアカウント側の`mailbox.role = ?`一致条件を外す
    /// (`nonGmailMatchesAnyMailbox`) — Gmail は既存どおり All Mail
    /// (`mailbox.role == .all`) 一つに絞る一方、`\All` special-useを持つ
    /// メールボックスがまず存在しない他アカウントでは「すべてのメール」＝
    /// 「そのアカウントの隠されていない mailbox すべて」という定義
    /// (`docs/design-system.md`の Task #141 節参照) にするための特別扱い。
    /// 他のどの role でもこの分岐は効かない (`nonGmailMatchesAnyMailbox`が
    /// 常に`false`)。
    ///
    /// Task #142: `pinnedOnly` — `request(mailboxId:limit:unreadOnly:
    /// pinnedOnly:)`のdoc comment参照、同じ`thread.isPinned = 1`条件。
    public static func unifiedInboxRequest(accountIds: [String], role: MailboxRoleRecord = .inbox, limit: Int? = nil, unreadOnly: Bool = false, pinnedOnly: Bool = false) -> SQLRequest<ThreadRecord> {
        guard !accountIds.isEmpty else {
            return SQLRequest(sql: "SELECT * FROM thread WHERE 0")
        }
        let placeholders = accountIds.map { _ in "?" }.joined(separator: ",")
        let nonGmailMatchesAnyMailbox = role == .all
        let nonGmailCondition = nonGmailMatchesAnyMailbox
            ? "account.kind != ?"
            : "(account.kind != ? AND mailbox.role = ?)"
        var sql = """
            SELECT thread.* FROM thread
            WHERE thread.accountId IN (\(placeholders))
              AND EXISTS (
                  SELECT 1 FROM message
                  JOIN mailbox ON mailbox.id = message.mailboxId
                  JOIN account ON account.id = mailbox.accountId
                  WHERE message.threadId = thread.id AND mailbox.accountId = thread.accountId
                        AND mailbox.isHidden = 0
                        AND (
                            (account.kind = ? AND mailbox.role = ?)
                            OR \(nonGmailCondition)
                        )
                        AND \(GmailArchiveFilter.excludeUnarchivedSQL)
              )
            """
        var arguments: [(any DatabaseValueConvertible)?] = accountIds
        arguments.append(contentsOf: [AccountKind.gmail.rawValue, role.gmailArchiveQueryRole.rawValue, AccountKind.gmail.rawValue])
        if !nonGmailMatchesAnyMailbox {
            arguments.append(role.rawValue)
        }
        if unreadOnly {
            sql += " AND thread.unreadCount > 0"
        }
        if pinnedOnly {
            sql += " AND thread.isPinned = 1"
        }
        sql += " ORDER BY thread.isPinned DESC, thread.lastMessageDate DESC, thread.id DESC"
        if let limit {
            sql += " LIMIT ?"
            arguments.append(limit)
        }
        return SQLRequest(sql: sql, arguments: StatementArguments(arguments))
    }

    /// Attaches each thread's newest message, for `ThreadSummary`-driven
    /// row rendering. One extra indexed point-lookup per thread — fine at
    /// M4's scale; a single-query join could replace this later if it ever
    /// shows up in profiling.
    public static func summaries(forThreads threads: [ThreadRecord], db: Database) throws -> [ThreadSummary] {
        try threads.map { thread in
            guard let threadId = thread.id else { return ThreadSummary(thread: thread, latestMessage: nil) }
            let latest = try MessageRecord
                .filter(Column("threadId") == threadId)
                .order(Column("internalDate").desc, Column("uid").desc)
                .fetchOne(db)
            var summary = ThreadSummary(thread: thread, latestMessage: latest)
            summary.isArchived = try isThreadArchived(threadId: threadId, db: db)
            return summary
        }
    }

    /// Task #151: per-thread "does at least one of this thread's messages
    /// live in a mailbox that counts as archived" check, backing
    /// `ThreadSummary.isArchived` for grouped-mode rows. One indexed EXISTS
    /// probe per thread — same "fine at M4's scale" reasoning as the
    /// per-thread `latestMessage` lookup in `summaries(forThreads:db:)`
    /// just above, which already pays an equivalent per-thread query cost.
    public static func isThreadArchived(threadId: Int64, db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (
                    SELECT 1 FROM message
                    JOIN mailbox ON mailbox.id = message.mailboxId
                    JOIN account ON account.id = mailbox.accountId
                    WHERE message.threadId = ? AND \(GmailArchiveFilter.messageIsArchivedSQL)
                )
                """,
            arguments: [threadId]
        ) ?? false
    }

    /// Task #151: the flat-mode (1 row = 1 message) counterpart to
    /// `isThreadArchived(threadId:db:)` — evaluates the same
    /// `GmailArchiveFilter.messageIsArchivedSQL` predicate against just that
    /// one message's own current mailbox membership rather than rolling up
    /// a whole thread.
    public static func isMessageArchived(messageId: Int64, db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT \(GmailArchiveFilter.messageIsArchivedSQL) FROM message
                JOIN mailbox ON mailbox.id = message.mailboxId
                JOIN account ON account.id = mailbox.accountId
                WHERE message.id = ?
                """,
            arguments: [messageId]
        ) ?? false
    }

    /// `limit` (M10 pagination — `MessageListView`'s "load more on scroll",
    /// docs/performance.md): `nil` keeps the pre-M10 "fetch everything"
    /// behavior for any caller that still wants it.
    public static func summariesObservation(mailboxId: Int64, limit: Int? = nil, unreadOnly: Bool = false, pinnedOnly: Bool = false) -> ValueObservation<ValueReducers.Fetch<[ThreadSummary]>> {
        ValueObservation.tracking { db in
            try summaries(forThreads: request(mailboxId: mailboxId, limit: limit, unreadOnly: unreadOnly, pinnedOnly: pinnedOnly).fetchAll(db), db: db)
        }
    }

    public static func unifiedInboxSummariesObservation(accountIds: [String], role: MailboxRoleRecord = .inbox, limit: Int? = nil, unreadOnly: Bool = false, pinnedOnly: Bool = false) -> ValueObservation<ValueReducers.Fetch<[ThreadSummary]>> {
        ValueObservation.tracking { db in
            try summaries(forThreads: unifiedInboxRequest(accountIds: accountIds, role: role, limit: limit, unreadOnly: unreadOnly, pinnedOnly: pinnedOnly).fetchAll(db), db: db)
        }
    }

    // MARK: - フラット表示 (B3)

    /// One row per *message* rather than per thread, for the "スレッドに
    /// まとめない" list-display setting — pinned messages first, then newest
    /// first, mirroring `request(mailboxId:limit:)`'s own ordering.
    /// `ThreadSummary(flatMessage:accountId:)` wraps each row so
    /// `ThreadRowView`/`MessageListRow`/`MessageListView`'s existing
    /// rendering and row actions need no changes to support this mode — see
    /// that initializer's doc comment.
    /// `unreadOnly` — flat mode has no `thread.unreadCount` aggregate to read
    /// (each row is one message, not a real thread rollup), so this filters
    /// on the message's own `flagsRaw` `\Seen` bit directly instead, matching
    /// `MessageQuery.unreadCounts(accountId:db:)`'s own SQL.
    /// Task #52 追記: `request(mailboxId:limit:unreadOnly:)`と同じ理由で
    /// Gmail の All Mail をアーカイブ定義でフィルタする — `SELECT message.*`
    /// にしているのは`mailbox`/`account`もJOINするようになった分、
    /// `SELECT *`だと余計な列 (`mailbox.id`等) が`MessageRecord`のデコードに
    /// 混ざってしまうのを避けるため。
    /// Task #142 追記: `pinnedOnly` — フラット表示は`thread.isPinned`の
    /// ような集計列を持たない (1行1メッセージ) ため、`unreadOnly`と同じく
    /// メッセージ自身の列を直接見る — `isPinnedLocal`は`MessageRecord`の
    /// 独立した`Bool`列 (`flagsRaw`のビットではない) なので、`unreadOnly`の
    /// ような`&`ビット演算は不要。
    public static func flatSummaries(mailboxId: Int64, limit: Int? = nil, accountId: String, unreadOnly: Bool = false, pinnedOnly: Bool = false, db: Database) throws -> [ThreadSummary] {
        var sql = """
            SELECT message.* FROM message
            JOIN mailbox ON mailbox.id = message.mailboxId
            JOIN account ON account.id = mailbox.accountId
            WHERE message.mailboxId = ?
                  AND \(GmailArchiveFilter.excludeUnarchivedSQL)
            """
        var arguments: [(any DatabaseValueConvertible)?] = [mailboxId]
        if unreadOnly {
            sql += " AND flagsRaw & \(MessageQuery.seenFlagBit) = 0"
        }
        if pinnedOnly {
            sql += " AND isPinnedLocal = 1"
        }
        sql += " ORDER BY isPinnedLocal DESC, COALESCE(date, internalDate) DESC, uid DESC"
        if let limit {
            sql += " LIMIT ?"
            arguments.append(limit)
        }
        let messages = try MessageRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        return try messages.map { message in
            var summary = ThreadSummary(flatMessage: message, accountId: accountId)
            if let messageId = message.id {
                summary.isArchived = try isMessageArchived(messageId: messageId, db: db)
            }
            return summary
        }
    }

    public static func flatSummariesObservation(mailboxId: Int64, limit: Int? = nil, accountId: String, unreadOnly: Bool = false, pinnedOnly: Bool = false) -> ValueObservation<ValueReducers.Fetch<[ThreadSummary]>> {
        ValueObservation.tracking { db in try flatSummaries(mailboxId: mailboxId, limit: limit, accountId: accountId, unreadOnly: unreadOnly, pinnedOnly: pinnedOnly, db: db) }
    }

    /// The flat-mode counterpart to `unifiedInboxRequest` — every account's
    /// inbox-role mailbox, interleaved. Needs `mailbox.accountId` per row
    /// (unlike the single-mailbox case above, where the caller already
    /// knows it), so this fetches plain `Row`s and decodes `MessageRecord`
    /// out of each one via its `FetchableRecord` conformance (GRDB's default
    /// `Decodable`-based decoding simply ignores the extra `accountId`
    /// column it doesn't declare a property for) rather than using
    /// `MessageRecord.fetchAll(db:sql:)` directly, which would only see the
    /// `message.*` columns.
    /// `unreadOnly` — same `flagsRaw` `\Seen`-bit filter as `flatSummaries`.
    /// `role` — see `unifiedInboxRequest(accountIds:role:limit:unreadOnly:)`'s
    /// doc comment; defaults to `.inbox` for every pre-existing call site.
    /// `account.kind`をJOINして参照する理由は`unifiedInboxRequest(accountIds:
    /// role:limit:unreadOnly:)`と同じ — Gmail のアーカイブマッピング
    /// (Task #52, 2)。`role == .all`の非Gmail特別扱い (Task #141) も同関数
    /// と同じ — その doc comment参照。`pinnedOnly` (Task #142) —
    /// `flatSummaries(mailboxId:limit:accountId:unreadOnly:pinnedOnly:db:)`
    /// と同じ`message.isPinnedLocal`列を直接見る。
    public static func unifiedInboxFlatSummaries(accountIds: [String], role: MailboxRoleRecord = .inbox, limit: Int? = nil, unreadOnly: Bool = false, pinnedOnly: Bool = false, db: Database) throws -> [ThreadSummary] {
        guard !accountIds.isEmpty else { return [] }
        let placeholders = accountIds.map { _ in "?" }.joined(separator: ",")
        let nonGmailMatchesAnyMailbox = role == .all
        let nonGmailCondition = nonGmailMatchesAnyMailbox
            ? "account.kind != ?"
            : "(account.kind != ? AND mailbox.role = ?)"
        var sql = """
            SELECT message.*, mailbox.accountId AS accountId FROM message
            JOIN mailbox ON mailbox.id = message.mailboxId
            JOIN account ON account.id = mailbox.accountId
            WHERE mailbox.accountId IN (\(placeholders)) AND mailbox.isHidden = 0
                  AND (
                      (account.kind = ? AND mailbox.role = ?)
                      OR \(nonGmailCondition)
                  )
                  AND \(GmailArchiveFilter.excludeUnarchivedSQL)
            """
        var arguments: [(any DatabaseValueConvertible)?] = accountIds
        arguments.append(contentsOf: [AccountKind.gmail.rawValue, role.gmailArchiveQueryRole.rawValue, AccountKind.gmail.rawValue])
        if !nonGmailMatchesAnyMailbox {
            arguments.append(role.rawValue)
        }
        if unreadOnly {
            sql += " AND message.flagsRaw & \(MessageQuery.seenFlagBit) = 0"
        }
        if pinnedOnly {
            sql += " AND message.isPinnedLocal = 1"
        }
        sql += " ORDER BY message.isPinnedLocal DESC, COALESCE(message.date, message.internalDate) DESC, message.uid DESC"
        if let limit {
            sql += " LIMIT ?"
            arguments.append(limit)
        }
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        return try rows.map { row in
            let message = try MessageRecord(row: row)
            let accountId: String = row["accountId"]
            var summary = ThreadSummary(flatMessage: message, accountId: accountId)
            if let messageId = message.id {
                summary.isArchived = try isMessageArchived(messageId: messageId, db: db)
            }
            return summary
        }
    }

    public static func unifiedInboxFlatSummariesObservation(accountIds: [String], role: MailboxRoleRecord = .inbox, limit: Int? = nil, unreadOnly: Bool = false, pinnedOnly: Bool = false) -> ValueObservation<ValueReducers.Fetch<[ThreadSummary]>> {
        ValueObservation.tracking { db in try unifiedInboxFlatSummaries(accountIds: accountIds, role: role, limit: limit, unreadOnly: unreadOnly, pinnedOnly: pinnedOnly, db: db) }
    }

    /// Every message in `threadId`, oldest first, deduplicated — what
    /// `ThreadDetailView` lays out vertically, collapsing everything but the
    /// newest. See `deduplicate(_:db:)`'s doc comment for why a Gmail thread
    /// can otherwise show the same physical email twice (real-device report:
    /// Gmail's dual mailbox membership, INBOX + All Mail, each synced as its
    /// own `message` row sharing one `gmailMessageId`).
    public static func messages(threadId: Int64, db: Database) throws -> [MessageRecord] {
        let raw = try MessageRecord
            .filter(Column("threadId") == threadId)
            .order(Column("internalDate"), Column("uid"))
            .fetchAll(db)
        return try deduplicate(raw, db: db)
    }

    /// Collapses rows that represent the *same physical message* synced
    /// twice under different `mailboxId`s — Gmail's dual-labeling model
    /// means every message lives in All Mail (`mailbox.role == .all`) *and*
    /// in whichever other special-use folder(s) apply (e.g. INBOX), and this
    /// app syncs each membership as its own `message` row. Both rows share
    /// the same `gmailMessageId` (`X-GM-MSGID`, already indexed —
    /// `message_on_gmailMessageId` in `AppDatabase.swift`) but different
    /// `mailboxId`, which without this step means a thread's accordion (and
    /// its message/unread counts, see `ThreadAssigner`) shows/counts the
    /// same email twice.
    ///
    /// Identity for dedup purposes: `gmailMessageId` when non-`nil` (the
    /// reliable Gmail-issued per-account-unique id — same reasoning
    /// `GmailArchiveFilter`'s doc comment gives for preferring it over the
    /// RFC 822 `Message-ID` header), else `messageId` (the RFC 822 header
    /// string) when *that* is non-`nil`. Rows where **both** are `nil` are
    /// never deduplicated against anything (including each other) — there's
    /// no safe signal that two such rows are the same message, so treating
    /// them as duplicates risks silently dropping genuinely distinct mail.
    ///
    /// When two or more rows share a non-`nil` identity key, this keeps
    /// exactly one: prefer a row sitting in a mailbox with a real role
    /// (`inbox`/`sent`/`drafts`/`trash`/`junk`/`archive`) over one in
    /// Gmail's catch-all All Mail (role `.all`, or the absence of any
    /// recognized role) — a role-bearing folder is the more natural one to
    /// display/act on, mirroring the "role over All Mail" preference
    /// `GmailArchiveFilter` already applies elsewhere. If more than one
    /// role-bearing (or more than one non-role-bearing) candidate remains —
    /// not expected in practice, but handled defensively rather than
    /// crashing — the tie-break is: greater `uid` wins; if `uid` also ties,
    /// the row encountered first (in the input list's order) wins. This
    /// tie-break has no meaning beyond "pick one deterministically" — don't
    /// depend on it as behavior.
    ///
    /// Preserves the input list's relative order: surviving rows keep the
    /// position of their first occurrence, so callers that already sorted
    /// (e.g. `messages(threadId:db:)`'s `internalDate`, `uid` order) don't
    /// need to re-sort afterward.
    static func deduplicate(_ messages: [MessageRecord], db: Database) throws -> [MessageRecord] {
        guard messages.count > 1 else { return messages }

        let mailboxIds = Set(messages.map(\.mailboxId))
        let roleByMailboxId: [Int64: MailboxRoleRecord] = try Dictionary(
            uniqueKeysWithValues: MailboxRecord
                .filter(mailboxIds.contains(Column("id")))
                .fetchAll(db)
                .compactMap { mailbox in mailbox.id.map { ($0, mailbox.role) } }
        )

        func isRoleBearing(_ mailboxId: Int64) -> Bool {
            switch roleByMailboxId[mailboxId] {
            case .some(.inbox), .some(.sent), .some(.drafts), .some(.trash), .some(.junk), .some(.archive):
                return true
            case .some(.all), .some(.none), .some(.flagged), Optional<MailboxRoleRecord>.none:
                return false
            }
        }

        func identityKey(_ message: MessageRecord) -> String? {
            if let gmailMessageId = message.gmailMessageId { return "gmail:\(gmailMessageId)" }
            if let messageId = message.messageId { return "msgid:\(messageId)" }
            return nil
        }

        // Pass 1: decide, per identity key, which row's `id` survives.
        var winnerIdForKey: [String: Int64] = [:]
        for message in messages {
            guard let key = identityKey(message), let id = message.id else { continue }
            guard let existingId = winnerIdForKey[key] else {
                winnerIdForKey[key] = id
                continue
            }
            guard let existing = messages.first(where: { $0.id == existingId }) else {
                winnerIdForKey[key] = id
                continue
            }
            let existingPreferred = isRoleBearing(existing.mailboxId)
            let candidatePreferred = isRoleBearing(message.mailboxId)
            if candidatePreferred != existingPreferred {
                if candidatePreferred { winnerIdForKey[key] = id }
            } else if message.uid > existing.uid {
                winnerIdForKey[key] = id
            }
        }

        // Pass 2: filter the original list, keeping every key-less row (or a
        // keyed row that was never registered above because its own `id`
        // was somehow `nil` — always true in practice since these are
        // records fetched back from the database, but kept here rather
        // than risk silently dropping a row) and exactly the chosen winner
        // for each key — in the input's order.
        var result: [MessageRecord] = []
        result.reserveCapacity(messages.count)
        for message in messages {
            guard let key = identityKey(message), let id = message.id else {
                result.append(message)
                continue
            }
            if winnerIdForKey[key] == id {
                result.append(message)
            }
        }
        return result
    }

    public static func messagesObservation(threadId: Int64) -> ValueObservation<ValueReducers.Fetch<[MessageRecord]>> {
        ValueObservation.tracking { db in try messages(threadId: threadId, db: db) }
    }

    /// 実機フィードバック第3弾 (A): what a row/swipe action's mutation should
    /// actually touch — every message in the underlying real thread for a
    /// grouped-mode row (`summary.singleMessageId == nil`, the pre-existing
    /// behavior), or just the one message a flat-mode row displays
    /// (`summary.singleMessageId != nil`). Before this existed, every
    /// `MessageListView` row action (既読/未読・アーカイブ・迷惑メール・
    /// ピン留め・削除) always operated on the whole real thread via
    /// `messages(threadId:db:)`, even from a flat row that visually shows
    /// only one message — a real-device report ("フラット表示でも操作が束で
    /// 効く") traced to exactly that mismatch. Re-fetches the single message
    /// fresh from `db` (not `summary.latestMessage`, which can be stale by
    /// the time an action actually runs) for the same freshness guarantee
    /// `messages(threadId:db:)` already gives the grouped-mode path.
    public static func actionTargets(for summary: ThreadSummary, db: Database) throws -> [MessageRecord] {
        if let messageId = summary.singleMessageId {
            return try MessageRecord.fetchOne(db, key: messageId).map { [$0] } ?? []
        }
        guard let threadId = summary.thread.id else { return [] }
        return try messages(threadId: threadId, db: db)
    }

    /// 新画面構成: メール本文画面「…」メニューの「スレッドをミュート」/「ミュート
    /// 解除」— see `ThreadRecord.isMuted`'s doc comment for what the flag
    /// does (list dimming only, not push suppression). A no-op if the
    /// thread no longer exists (e.g. a race with it being deleted).
    public static func setMuted(threadId: Int64, muted: Bool, db: Database) throws {
        guard var thread = try ThreadRecord.fetchOne(db, key: threadId) else { return }
        guard thread.isMuted != muted else { return }
        thread.isMuted = muted
        try thread.update(db, columns: [Column("isMuted")])
    }
}
