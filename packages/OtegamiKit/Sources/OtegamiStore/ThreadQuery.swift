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
    ///
    /// **これは「アーカイブ済みの可視化」バッジ専用の OR 集約** — アーカイブ/
    /// アーカイブ解除の**スロット切り替えには使わないこと**。使うと
    /// `isThreadFullyArchived(threadId:db:)` の doc comment にある実機報告
    /// (親がアーカイブ済みのスレッドで新着をアーカイブできない) が再発する。
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

    /// 実機報告 (2026-08-27)「スレッドの親がアーカイブ済みだと、新しく来た
    /// メールをアーカイブできない」: `isThreadArchived(threadId:db:)` の
    /// **AND 集約**版 — 「このスレッドにまだアーカイブできる行が1つも
    /// 残っていない」。アーカイブ/アーカイブ解除**スロットの切り替え**は
    /// こちらを使う (バッジの「一部アーカイブ済みの可視化」= Task #151 の
    /// OR 集約は上の `isThreadArchived` のまま — 状態表示と「押したら何が
    /// 起きるか」は役割が違うので、食い違ってよい)。
    ///
    /// **なぜ OR ではだめだったか**: Task #184 は詳細画面のスロット切替に
    /// OR 集約を使い、「一部だけアーカイブ済みのスレッドは、その1通を解除
    /// するまで残りをアーカイブできなくなる」を narrow edge case として
    /// 受け入れていた。実際には「読み終えてアーカイブ → 返信が届く」という
    /// 日常動作で必ず踏む: スロットが「アーカイブ解除」に化け、
    /// `MessageRemoval.commit(.unarchive)` はアーカイブ場所にある行しか
    /// 触らないので新着は素通り、押しても何も起きない (しかも `commit` の
    /// `nil` は呼び出し側が握り潰すので無音) という報告になった。
    ///
    /// 述語は「アーカイブ済みでない行の非存在」であって「アーカイブ済みの
    /// 行の全称」ではない — `MessageRemoval.commit(.archive)` の
    /// `isAlreadyArchived` ガード (同じ `messageIsArchivedSQL`) を通過する
    /// 行の有無とちょうど一致させるため。これでスロットの表示と `commit`
    /// が実際に処理する対象が構造的にずれなくなり、「アーカイブ」を押して
    /// 無音で終わる経路が消える。空スレッド (行が1つも無い) は `false` —
    /// アーカイブできる行が無いことを「全部アーカイブ済み」とは呼ばない。
    ///
    /// 内側の条件が `NOT (...)` ではなく `(...) IS NOT 1` なのは、判定不能を
    /// 安全側へ倒すため。`mailbox.role`/`account.kind` は現在のスキーマでは
    /// NOT NULL の enum なので `messageIsArchivedSQL` が NULL になる経路は
    /// 無く、今は両者同値。ただし `NOT NULL_value` は NULL (= WHERE で偽) に
    /// なるので、万一 NULL が混じると素の `NOT` はその行を「アーカイブできる
    /// 行」として数え損ね、`true` = 「アーカイブ解除」スロットへ倒れて元の
    /// 無反応バグが再発する。`IS NOT 1` なら NULL も 0 と同じく「まだ
    /// アーカイブされていない」側に落ち、より安全なスロット (「アーカイブ」)
    /// が選ばれる。
    public static func isThreadFullyArchived(threadId: Int64, db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (SELECT 1 FROM message WHERE message.threadId = ?)
                   AND NOT EXISTS (
                    SELECT 1 FROM message
                    JOIN mailbox ON mailbox.id = message.mailboxId
                    JOIN account ON account.id = mailbox.accountId
                    WHERE message.threadId = ? AND \(GmailArchiveFilter.messageIsArchivedSQL) IS NOT 1
                )
                """,
            arguments: [threadId, threadId]
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

    /// 「迷惑メール解除」: the `.junk` counterpart to `isThreadArchived
    /// (threadId:db:)` — does at least one of this thread's messages
    /// currently live in a Junk-role mailbox. Same OR-aggregate semantics
    /// (and the same reason for them) as the archived check just above; the
    /// predicate is a plain role match because "迷惑メール" is a real folder
    /// on every provider, Gmail included (no `GmailArchiveFilter`-style
    /// special case needed). `isThreadArchived(threadId:db:)` と同じく
    /// **表示用の OR 集約** — スロットの切り替えには
    /// `isThreadFullyJunk(threadId:db:)` を使うこと。
    public static func isThreadJunk(threadId: Int64, db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (
                    SELECT 1 FROM message
                    JOIN mailbox ON mailbox.id = message.mailboxId
                    WHERE message.threadId = ? AND mailbox.role = 'junk'
                )
                """,
            arguments: [threadId]
        ) ?? false
    }

    /// 「迷惑メール解除」: `isThreadFullyArchived(threadId:db:)` の迷惑メール
    /// 版 — スロットの切り替えに使う AND 集約。同じ理由 (そちらの doc
    /// comment 参照): OR 集約だと「一部だけ迷惑メールのスレッド」で
    /// 「迷惑メール解除」に化け、`MessageRemoval.commit(.unjunk)` が Junk に
    /// いる行しか触らないため、残りを迷惑メールにする操作が無音で失敗する。
    /// 迷惑メール判定はメール単位なので、この混在はアーカイブと同じくらい
    /// 普通に起きる。
    public static func isThreadFullyJunk(threadId: Int64, db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (SELECT 1 FROM message WHERE message.threadId = ?)
                   AND NOT EXISTS (
                    SELECT 1 FROM message
                    JOIN mailbox ON mailbox.id = message.mailboxId
                    WHERE message.threadId = ? AND mailbox.role IS NOT 'junk'
                )
                """,
            arguments: [threadId, threadId]
        ) ?? false
    }

    /// The flat-mode (1 row = 1 message) counterpart to
    /// `isThreadJunk(threadId:db:)` — evaluates the same role match against
    /// just that one message's own current mailbox membership.
    public static func isMessageJunk(messageId: Int64, db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT mailbox.role = 'junk' FROM message
                JOIN mailbox ON mailbox.id = message.mailboxId
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
    /// exactly one. **Before anything else**: a `MessageRecord
    /// .isPendingRelocation` row (`uid <= 0`, a synthetic placeholder
    /// `MessageRemoval.commit` created ahead of the server — see that
    /// column's doc comment) always loses to a row with a real `uid >= 1`,
    /// regardless of role. 実機報告 (2026-08-16, Gmail アカウント)「特定の
    /// 1通に対して削除・アーカイブ解除・未読化が完全無反応」の根本原因:
    /// role-preference だけで決めていたため、role を持つメールボックス
    /// (例: Trash) に取り残された仮 UID 行が、role の無い All Mail の本物の
    /// 行より優先されてしまい、ユーザーが実際に見て操作するのが決して
    /// 昇格しない「ゴースト」行になっていた — その行への移送系操作は
    /// `MessageRemoval.commit`内の `UInt32(exactly:)` ガードに常に弾かれ、
    /// エラー表示も無いまま完全に無反応になる (詳しくはそのガードの doc
    /// comment 参照)。ゴーストを最優先で負けさせることで、本物の行が代表と
    /// して選ばれ操作可能になる。
    ///
    /// その次に、role の無いゴーストではない同士、あるいは role 付き同士が
    /// 残った場合: 実在するメールボックスの role
    /// (`inbox`/`sent`/`drafts`/`trash`/`junk`/`archive`) を持つ行を、
    /// Gmail の catch-all All Mail (role `.all`、または未知の role) の行より
    /// 優先する — role 付きフォルダの方が表示・操作対象として自然、という
    /// `GmailArchiveFilter` が他所で既に採用している「role を All Mail より
    /// 優先する」という判断をここでも踏襲している。それでも複数の
    /// role 付き (または複数の role 無し) 候補が残る場合 — 実運用では
    /// 想定していないが、クラッシュせず防御的に扱う — 最後のタイブレークは
    /// 「`uid` が大きい方が勝つ」、それも同じなら「入力リストで先に出てきた
    /// 方が勝つ」。このタイブレークに「決定的に1つ選ぶ」以上の意味は無い —
    /// 挙動として依存しないこと。
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
            let existingIsGhost = existing.isPendingRelocation
            let candidateIsGhost = message.isPendingRelocation
            if candidateIsGhost != existingIsGhost {
                // A real `uid >= 1` row always wins over a synthetic
                // placeholder, regardless of role — see this function's
                // doc comment for the real-device bug this fixes.
                if !candidateIsGhost { winnerIdForKey[key] = id }
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

    /// `deduplicate(_:db:)` が「同じ物理メッセージ」として畳んだ**残りの
    /// 行**を返す (`message` 自身は含まない)。
    ///
    /// 実機報告 (2026-08-07)「メールの unpin が反映されない」の修正で
    /// 追加した。Gmail の二重ラベルでは同じメールが INBOX と All Mail の
    /// 2行として同期される。`actionTargets(for:db:)` は `messages
    /// (threadId:db:)` 経由で **dedup 済みの代表行しか返さない**ので、
    /// ローカル状態 (`isPinnedLocal`/`\Seen`) をそこだけ書き換えると、
    /// 破棄された側の行は古い値のまま残る。ところが `ThreadRecord
    /// .isPinned` の集約は dedup 前の全行の OR (`ThreadAssigner
    /// .recomputeAggregates`、SQL 側も `MAX(message.isPinnedLocal)`) なので、
    /// **ピン留めは効くのに解除だけ効かない**という非対称が生まれていた
    /// (OR は片方が残っていれば `true` のまま)。
    ///
    /// 探索は `message` の `threadId` 内に限定する — `deduplicate` が
    /// 見ている集合と正確に同じにするため (RFC 822 `Message-ID` は転送等で
    /// 別スレッドの行と一致しうるので、スレッドを跨いで畳むのは危険)。
    /// 同一性の判定 (`identityKey`) は `deduplicate` とそのまま共有する。
    ///
    /// サーバーへ送る op は代表行のぶんだけでよい — Gmail のフラグ
    /// (`\Flagged`/`\Seen`) はラベルではなくメッセージに付くので、どちらの
    /// ラベル経由で STORE しても両方に反映される。ここで揃えるのは
    /// あくまでローカル DB の整合性。
    public static func duplicateSiblings(of message: MessageRecord, db: Database) throws -> [MessageRecord] {
        guard let threadId = message.threadId, let messageId = message.id,
              let key = identityKey(message)
        else { return [] }
        return try MessageRecord
            .filter(Column("threadId") == threadId)
            .fetchAll(db)
            .filter { $0.id != messageId && identityKey($0) == key }
    }

    /// `duplicateSiblings(of:db:)`の「行ではなく UID だけ、しかもまとめて」
    /// 版 — `originMailboxId` の `originUIDs` が指す物理メッセージと同じ
    /// ものを指す、`siblingMailboxId` 側の行の UID を返す。
    ///
    /// 実機報告 (2026-08-07)「メールの unpin が反映されない」の**2度目の**
    /// 修正で追加した。1度目 (`duplicateSiblings(of:db:)`) はローカル DB の
    /// 整合だけを直したが、同期側のガード (`SyncEngine.PendingOpTargets`)
    /// が兄弟行をカバーしていなかったため、サーバーの `\Flagged` が
    /// All Mail 側の行をすぐ `true` に戻し、`ThreadRecord.isPinned` の
    /// OR 集約でピンが残り続けていた。そのガードがこの関数を使って
    /// 「未送信の `setFlags` op が守るべき UID」を兄弟行まで広げる。
    ///
    /// **`gmailMessageId` の有無で同一性キーが変わる非対称をそのまま SQL に
    /// 写していることに注意** — `identityKey` は `gmailMessageId` を優先
    /// するので、片方が `gmail:X`・もう片方が `msgid:Y` のときは**キーが
    /// 違う**(重複ではない)。素直に `OR sibling.messageId = origin.messageId`
    /// と書くと `deduplicate` と食い違うので、`messageId` での一致は
    /// **両方の `gmailMessageId` が `NULL` のときだけ**に限定している。
    ///
    /// 探索を `threadId` 一致に絞る理由は `duplicateSiblings(of:db:)` と
    /// 同じ (RFC 822 `Message-ID` は転送等で別スレッドの行と一致しうる)。
    /// インデックスは `message`の`(mailboxId, uid)`一意制約と
    /// `message_on_threadId_mailboxId` で足りるので、この関数のために
    /// 新しいインデックスは要らない。
    public static func duplicateSiblingUIDs(
        ofUIDs originUIDs: Set<Int64>,
        in originMailboxId: Int64,
        siblingMailboxId: Int64,
        db: Database
    ) throws -> Set<Int64> {
        guard !originUIDs.isEmpty, originMailboxId != siblingMailboxId else { return [] }
        var result: Set<Int64> = []
        // `ThreadAssigner.apply`のバッチ更新と同じ理由・同じ粒度のチャンク —
        // SQLite の変数上限 (`SQLITE_MAX_VARIABLE_NUMBER`) に当たらないように
        // するため。
        for chunk in Array(originUIDs).chunked(into: 400) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            var arguments: [any DatabaseValueConvertible] = [siblingMailboxId, originMailboxId]
            arguments.append(contentsOf: chunk)
            let uids = try Int64.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT sibling.uid
                    FROM message AS origin
                    JOIN message AS sibling
                      ON sibling.threadId = origin.threadId
                     AND sibling.mailboxId = ?
                     AND sibling.id <> origin.id
                     AND (
                             (origin.gmailMessageId IS NOT NULL AND sibling.gmailMessageId = origin.gmailMessageId)
                          OR (origin.gmailMessageId IS NULL AND sibling.gmailMessageId IS NULL
                              AND origin.messageId IS NOT NULL AND sibling.messageId = origin.messageId)
                         )
                    WHERE origin.mailboxId = ? AND origin.threadId IS NOT NULL
                          AND origin.uid IN (\(placeholders))
                    """,
                arguments: StatementArguments(arguments)
            )
            result.formUnion(uids)
        }
        return result
    }

    /// `deduplicate(_:db:)`/`duplicateSiblings(of:db:)`が共有する同一性の
    /// キー — `gmailMessageId` (Gmail 発行の per-account 一意な
    /// `X-GM-MSGID`) を優先し、無ければ RFC 822 `Message-ID`。どちらも
    /// `nil` の行は何とも重複扱いしない (安全な手がかりが無いため)。
    /// `duplicateSiblingUIDs(ofUIDs:in:siblingMailboxId:db:)`はこの判定を
    /// SQL へ写したもの — 変更するときは両方を揃えること。
    private static func identityKey(_ message: MessageRecord) -> String? {
        if let gmailMessageId = message.gmailMessageId { return "gmail:\(gmailMessageId)" }
        if let messageId = message.messageId { return "msgid:\(messageId)" }
        return nil
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
}
