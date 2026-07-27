import Foundation
import GRDB

/// Where a search should look: every account's every mailbox ("すべて"), or
/// just one specific mailbox ("現在のメールボックス") — the two modes the
/// plan calls for ("全アカウント横断 (統合) + 現在のメールボックス内絞り込みの
/// 2 モード"). Deliberately not restricted to inbox-role mailboxes the way
/// `ThreadQuery.unifiedInboxRequest` is — search should find a message
/// wherever it's stored (Sent, Archive, ...), not just the inbox.
public enum SearchScope: Sendable, Equatable {
    case allAccounts(accountIds: [String])
    case mailbox(mailboxId: Int64)
}

/// Interprets a raw search-bar string against `messageSearchIndex`/`message`
/// and returns matching threads, grouped and ordered the same way
/// `ThreadQuery` does for a plain mailbox listing — so `SearchView` can
/// render results with the exact same `ThreadRow` a normal message list
/// uses.
/// A raw search-bar string, split into its header operators (`from:`/`to:`/
/// `cc:`/`subject:`) and whatever free text is left over — 新画面構成の検索
/// 演算子 ("演算子部分は全文検索ではなくヘッダに対する条件として解釈し、残りの
/// テキストは通常の全文検索"). `SearchQuery.parse(_:)` builds one from a raw
/// string; `SearchQuery.threadSummaries` is the only place that consumes it.
public struct ParsedSearchQuery: Sendable, Equatable {
    public var freeText: String
    public var from: String?
    public var to: String?
    public var cc: String?
    public var subject: String?

    /// `true` when there's nothing at all to search on (no free text and no
    /// operator) — the same "an empty query returns no results" rule
    /// `threadSummaries` already applied to a plain blank string, extended
    /// to also cover "only whitespace, no operators either."
    public var isEmpty: Bool {
        freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && from == nil && to == nil && cc == nil && subject == nil
    }
}

public enum SearchQuery {
    /// Below this many `Character`s (not UTF-8 bytes — a query's *meaning*
    /// scales with grapheme count, not byte count, which matters a lot for
    /// CJK text) SQLite's trigram tokenizer reduces a query to zero tokens
    /// and a `MATCH` finds nothing no matter what's indexed (confirmed by
    /// `SearchQueryTests`'s boundary test), so `threadSummaries` switches to
    /// a `LIKE` scan instead (plan: "1〜2 文字 → LIKE フォールバック").
    public static let minimumFTSLength = 3

    /// How many threads a search returns by default when a caller doesn't
    /// specify its own `limit` — mirrors `ThreadQuery`'s pagination (M10,
    /// docs/performance.md). Without *some* cap, a broad-but-short query
    /// (e.g. a common word matching a large fraction of a 100k-message
    /// mailbox) forces `ThreadQuery.summaries(forThreads:)`'s one-
    /// point-lookup-per-thread pattern to run tens of thousands of times —
    /// confirmed while building `PerformanceTests`: an unbounded query
    /// matching 80k threads took ~14.5s, entirely from that fan-out, not
    /// from `matchFTS`/`matchLIKE` themselves (each well under 100ms on
    /// their own). A search results list this large isn't useful to a human
    /// either way — "narrow your search" is the right UX for that case, not
    /// "wait 14 seconds to see all 80,000."
    public static let defaultResultLimit = 200

    /// Recognized header-operator prefixes (新画面構成の検索演算子) —
    /// case-insensitive, ASCII only (matches the operator names themselves,
    /// not the values after the colon). A plain `[String]` (rather than a
    /// table of prefix→closure pairs) so `parse(_:)`'s `switch` below stays
    /// the one and only place that knows what each operator actually does —
    /// also sidesteps Swift 6 strict concurrency flagging a `static let` of
    /// closures as non-`Sendable` shared mutable state.
    private static let operatorPrefixes = ["from:", "to:", "cc:", "subject:"]

    /// Splits a raw search-bar string into its recognized `operator:value`
    /// tokens and whatever's left over as free text (plan: "`from:aaa@bbb
    /// .com` で from 絞り込み。`to:`/`cc:`/`subject:` にも対応"). Tokenizes on
    /// whitespace — an operator's value can't itself contain a space (e.g.
    /// `from:"a b"` isn't supported), which matches how every mainstream
    /// mail client's search-operator syntax works and keeps this a simple,
    /// single-pass token scan rather than a small quoted-string parser.
    /// Only the *last* occurrence of a given operator wins if it's repeated
    /// (e.g. `from:a from:b` behaves as `from:b`) — simpler than merging
    /// duplicates, and a user typing the same operator twice is almost
    /// certainly correcting themselves, not asking for an OR.
    public static func parse(_ raw: String) -> ParsedSearchQuery {
        var parsed = ParsedSearchQuery(freeText: "", from: nil, to: nil, cc: nil, subject: nil)
        var freeWords: [String] = []
        for token in raw.split(separator: " ", omittingEmptySubsequences: true) {
            let word = String(token)
            guard let prefix = operatorPrefixes.first(where: { word.lowercased().hasPrefix($0) }) else {
                freeWords.append(word)
                continue
            }
            let value = String(word.dropFirst(prefix.count))
            guard !value.isEmpty else {
                // A bare `from:` with nothing after it isn't a usable
                // operator — treat the whole token as free text instead of
                // silently discarding it.
                freeWords.append(word)
                continue
            }
            switch prefix {
            case "from:": parsed.from = value
            case "to:": parsed.to = value
            case "cc:": parsed.cc = value
            case "subject:": parsed.subject = value
            default: freeWords.append(word)
            }
        }
        parsed.freeText = freeWords.joined(separator: " ")
        return parsed
    }

    /// Runs `query` against `scope`, returning matching threads newest
    /// first (plan: "結果はスコアでなく date DESC で十分" — no relevance ranking).
    /// An empty/whitespace-only query returns no results rather than every
    /// thread (there is no such thing as "browse mode" via the search bar)
    /// — extended (新画面構成) so a query that's *only* operators (no free
    /// text left over, e.g. `from:aaa@bbb.com` alone) still runs, matched
    /// purely on those operators. `limit` caps how many threads are
    /// returned — see ``defaultResultLimit``'s doc comment for why one
    /// exists at all; pass `nil` for the pre-M10 "no cap" behavior.
    public static func threadSummaries(query: String, scope: SearchScope, limit: Int? = defaultResultLimit, db: Database) throws -> [ThreadSummary] {
        try threadSummaries(parsed: parse(query), scope: scope, limit: limit, db: db)
    }

    /// The operator-aware entry point `threadSummaries(query:scope:limit:db:)`
    /// delegates to — also callable directly by a caller that already
    /// parsed the raw text itself (e.g. to render which operators are
    /// active as chips) and doesn't want to re-parse it.
    public static func threadSummaries(parsed: ParsedSearchQuery, scope: SearchScope, limit: Int? = defaultResultLimit, db: Database) throws -> [ThreadSummary] {
        guard !parsed.isEmpty else { return [] }

        // Each operator/free-text component narrows the result set further
        // (AND semantics — a message must satisfy every one that's
        // present), computed as `Set<Int64>` intersections rather than a
        // single combined SQL query: the free-text side already branches
        // between two entirely different matching strategies (FTS trigram
        // vs. LIKE, `matchFTS`/`matchLIKE`'s own doc comments), so folding
        // per-operator `LIKE` clauses into that same SQL would mean
        // duplicating each strategy's WHERE-building twice over. Every
        // component here already runs against `scope`, so the intersection
        // never needs to re-check scope itself.
        var messageIds: Set<Int64>?
        func narrow(_ ids: [Int64]) {
            messageIds = messageIds.map { $0.intersection(ids) } ?? Set(ids)
        }

        let trimmedFreeText = parsed.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFreeText.isEmpty {
            let ids = trimmedFreeText.count >= minimumFTSLength
                ? try matchFTS(trimmedFreeText, scope: scope, db: db)
                : try matchLIKE(trimmedFreeText, scope: scope, db: db)
            narrow(ids)
        }
        if let from = parsed.from { narrow(try matchColumn("fromText", value: from, scope: scope, db: db)) }
        if let to = parsed.to { narrow(try matchColumn("toText", value: to, scope: scope, db: db)) }
        if let cc = parsed.cc { narrow(try matchColumn("ccText", value: cc, scope: scope, db: db)) }
        if let subject = parsed.subject { narrow(try matchColumn("subject", value: subject, scope: scope, db: db)) }

        guard let messageIds, !messageIds.isEmpty else { return [] }
        let messageIdsArray = Array(messageIds)

        let threadIds = try Int64.fetchAll(
            db,
            sql: """
                SELECT DISTINCT threadId FROM message
                WHERE id IN (\(messageIdsArray.map { _ in "?" }.joined(separator: ","))) AND threadId IS NOT NULL
                """,
            arguments: StatementArguments(messageIdsArray)
        )
        guard !threadIds.isEmpty else { return [] }

        var request = ThreadRecord
            .filter(threadIds.contains(Column("id")))
            .order(Column("lastMessageDate").desc, Column("id").desc)
        if let limit {
            request = request.limit(limit)
        }
        let threads = try request.fetchAll(db)
        return try ThreadQuery.summaries(forThreads: threads, db: db)
    }

    /// B3 フラット表示 + 検索: the message-level counterpart to
    /// `threadSummaries(query:scope:limit:db:)` — one row per matching
    /// *message* rather than one row per thread, mirroring the same split
    /// `ThreadQuery.request`/`unifiedInboxRequest` (グループ化) already has
    /// against `ThreadQuery.flatSummaries`/`unifiedInboxFlatSummaries`
    /// (フラット). Added in response to a real-device report ("スレッド表示を
    /// オフにしてるのに、スレッドで表示されることがある"): this method
    /// (grouped search) was, until this fix, the *only* place in the app
    /// that still always grouped results by thread regardless of
    /// `ListDisplaySettingsStore.threadingKey` — every other list surface
    /// (`MessageListView.observeThreads()`) already branched on it. A prior
    /// pass explicitly judged that gap acceptable ("search results are a
    /// comparatively small, transient list where grouped vs. flat matters
    /// far less") without live device verification; an actual user hitting
    /// it means that judgment call didn't hold up in practice.
    public static func flatMessageSummaries(query: String, scope: SearchScope, limit: Int? = defaultResultLimit, db: Database) throws -> [ThreadSummary] {
        try flatMessageSummaries(parsed: parse(query), scope: scope, limit: limit, db: db)
    }

    /// The operator-aware entry point `flatMessageSummaries(query:scope:
    /// limit:db:)` delegates to — mirrors `threadSummaries(parsed:scope:
    /// limit:db:)`'s own split between the two entry points, same reason.
    public static func flatMessageSummaries(parsed: ParsedSearchQuery, scope: SearchScope, limit: Int? = defaultResultLimit, db: Database) throws -> [ThreadSummary] {
        guard !parsed.isEmpty else { return [] }

        // Identical matching (per-operator `Set<Int64>` intersection) to
        // `threadSummaries(parsed:scope:limit:db:)` above — only what
        // happens *after* the matching message id set is computed differs
        // (grouped into threads there, kept as individual messages here).
        var messageIds: Set<Int64>?
        func narrow(_ ids: [Int64]) {
            messageIds = messageIds.map { $0.intersection(ids) } ?? Set(ids)
        }

        let trimmedFreeText = parsed.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFreeText.isEmpty {
            let ids = trimmedFreeText.count >= minimumFTSLength
                ? try matchFTS(trimmedFreeText, scope: scope, db: db)
                : try matchLIKE(trimmedFreeText, scope: scope, db: db)
            narrow(ids)
        }
        if let from = parsed.from { narrow(try matchColumn("fromText", value: from, scope: scope, db: db)) }
        if let to = parsed.to { narrow(try matchColumn("toText", value: to, scope: scope, db: db)) }
        if let cc = parsed.cc { narrow(try matchColumn("ccText", value: cc, scope: scope, db: db)) }
        if let subject = parsed.subject { narrow(try matchColumn("subject", value: subject, scope: scope, db: db)) }

        guard let messageIds, !messageIds.isEmpty else { return [] }
        let messageIdsArray = Array(messageIds)

        // `mailbox.accountId`をJOINで一緒に取得する — `ThreadQuery
        // .unifiedInboxFlatSummaries`と同じ「`ThreadSummary(flatMessage:
        // accountId:)`が要求するaccountIdをRowから直接読む」パターン
        // (`MessageRecord`自身は`accountId`列を持たないため)。
        var sql = """
            SELECT message.*, mailbox.accountId AS accountId FROM message
            JOIN mailbox ON mailbox.id = message.mailboxId
            WHERE message.id IN (\(messageIdsArray.map { _ in "?" }.joined(separator: ",")))
            ORDER BY message.isPinnedLocal DESC, COALESCE(message.date, message.internalDate) DESC, message.uid DESC
            """
        var arguments: [(any DatabaseValueConvertible)?] = messageIdsArray
        if let limit {
            sql += " LIMIT ?"
            arguments.append(limit)
        }
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        return try rows.map { row in
            let message = try MessageRecord(row: row)
            let accountId: String = row["accountId"]
            return ThreadSummary(flatMessage: message, accountId: accountId)
        }
    }

    // MARK: - FTS5 trigram (query length >= minimumFTSLength)

    private static func matchFTS(_ query: String, scope: SearchScope, db: Database) throws -> [Int64] {
        let matchExpression = ftsMatchExpression(for: query)
        guard !matchExpression.isEmpty else { return [] }
        let (scopeSQL, scopeArgs) = scopeClause(scope, messageAlias: "message")
        let sql = """
            SELECT message.id FROM message
            JOIN messageSearchIndex ON messageSearchIndex.rowid = message.id
            JOIN mailbox ON mailbox.id = message.mailboxId
            WHERE messageSearchIndex MATCH ? \(scopeSQL)
            """
        var arguments: [(any DatabaseValueConvertible)?] = [matchExpression]
        arguments.append(contentsOf: scopeArgs)
        return try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
    }

    /// Splits `query` on whitespace into words, quotes each as an FTS5
    /// phrase — doubling any embedded `"` (FTS5's own escape for a literal
    /// quote inside a quoted string) — and joins them with `AND` (plan:
    /// "フレーズとして quote、AND 複数語対応"): every word must appear
    /// somewhere in a matching row's indexed columns, but not necessarily
    /// contiguously or in the same column.
    static func ftsMatchExpression(for query: String) -> String {
        let words = query.split(whereSeparator: \.isWhitespace)
        let phrases = words.map { word -> String in
            let escaped = word.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return phrases.joined(separator: " AND ")
    }

    // MARK: - LIKE fallback (query length < minimumFTSLength)

    private static func matchLIKE(_ query: String, scope: SearchScope, db: Database) throws -> [Int64] {
        let pattern = "%\(likeEscape(query))%"
        let (scopeSQL, scopeArgs) = scopeClause(scope, messageAlias: "message")
        // M10 perf note (docs/performance.md): no `DISTINCT` here — unlike a
        // fan-out join, `message.id` is already unique per output row
        // (`messageBody`/`mailbox` are both joined 1:1 by primary key), so
        // `DISTINCT` was pure overhead (an extra temp-b-tree dedup pass over
        // a result set that could never have duplicates in the first
        // place). Measured ~15% faster on a 100k-message synthetic mailbox
        // with this removed — the dominant cost is still the unavoidable
        // full-table LIKE scan (no index can serve a leading-wildcard
        // pattern), which is why short (<3 character) queries stay slower
        // than the FTS trigram path; see `SearchQuery.minimumFTSLength`'s
        // doc comment for why that threshold exists at all.
        let sql = """
            SELECT message.id FROM message
            LEFT JOIN messageBody ON messageBody.messageId = message.id
            JOIN mailbox ON mailbox.id = message.mailboxId
            WHERE (
                message.subject LIKE ? ESCAPE '\\'
                OR messageBody.plainText LIKE ? ESCAPE '\\'
                OR message.fromText LIKE ? ESCAPE '\\'
            ) \(scopeSQL)
            """
        var arguments: [(any DatabaseValueConvertible)?] = [pattern, pattern, pattern]
        arguments.append(contentsOf: scopeArgs)
        return try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
    }

    /// Escapes `%`/`_`/the escape character itself (backslash) so a `LIKE`
    /// pattern built from raw user input can't accidentally invoke SQL
    /// wildcard syntax — e.g. a literal search for `50%` must not match
    /// every subject containing "50" followed by anything.
    static func likeEscape(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        for character in raw {
            switch character {
            case "\\", "%", "_":
                result.append("\\")
                result.append(character)
            default:
                result.append(character)
            }
        }
        return result
    }

    // MARK: - Header operators (新画面構成の検索演算子)

    /// Matches `message.<column> LIKE %value%` — the shared implementation
    /// behind every header operator (`from:`/`to:`/`cc:`/`subject:`).
    /// `column` is always one of a small fixed set of literal strings this
    /// file itself passes in (never user input), so interpolating it
    /// directly into the SQL text is safe; `value` (genuine user input)
    /// only ever appears as a bound `?` parameter.
    private static func matchColumn(_ column: String, value: String, scope: SearchScope, db: Database) throws -> [Int64] {
        let pattern = "%\(likeEscape(value))%"
        let (scopeSQL, scopeArgs) = scopeClause(scope, messageAlias: "message")
        let sql = """
            SELECT message.id FROM message
            JOIN mailbox ON mailbox.id = message.mailboxId
            WHERE message.\(column) LIKE ? ESCAPE '\\' \(scopeSQL)
            """
        var arguments: [(any DatabaseValueConvertible)?] = [pattern]
        arguments.append(contentsOf: scopeArgs)
        return try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
    }

    // MARK: - Scope

    private static func scopeClause(
        _ scope: SearchScope,
        messageAlias: String
    ) -> (sql: String, args: [(any DatabaseValueConvertible)?]) {
        switch scope {
        case .allAccounts(let accountIds):
            guard !accountIds.isEmpty else { return ("AND 0", []) }
            let placeholders = accountIds.map { _ in "?" }.joined(separator: ",")
            return ("AND mailbox.accountId IN (\(placeholders))", accountIds)
        case .mailbox(let mailboxId):
            return ("AND \(messageAlias).mailboxId = ?", [mailboxId])
        }
    }
}
