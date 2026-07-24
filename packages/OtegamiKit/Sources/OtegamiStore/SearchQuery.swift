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
public enum SearchQuery {
    /// Below this many `Character`s (not UTF-8 bytes — a query's *meaning*
    /// scales with grapheme count, not byte count, which matters a lot for
    /// CJK text) SQLite's trigram tokenizer reduces a query to zero tokens
    /// and a `MATCH` finds nothing no matter what's indexed (confirmed by
    /// `SearchQueryTests`'s boundary test), so `threadSummaries` switches to
    /// a `LIKE` scan instead (plan: "1〜2 文字 → LIKE フォールバック").
    public static let minimumFTSLength = 3

    /// Runs `query` against `scope`, returning matching threads newest
    /// first (plan: "結果はスコアでなく date DESC で十分" — no relevance ranking).
    /// An empty/whitespace-only query returns no results rather than every
    /// thread (there is no such thing as "browse mode" via the search bar).
    public static func threadSummaries(query: String, scope: SearchScope, db: Database) throws -> [ThreadSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let messageIds = trimmed.count >= minimumFTSLength
            ? try matchFTS(trimmed, scope: scope, db: db)
            : try matchLIKE(trimmed, scope: scope, db: db)
        guard !messageIds.isEmpty else { return [] }

        let threadIds = try Int64.fetchAll(
            db,
            sql: """
                SELECT DISTINCT threadId FROM message
                WHERE id IN (\(messageIds.map { _ in "?" }.joined(separator: ","))) AND threadId IS NOT NULL
                """,
            arguments: StatementArguments(messageIds)
        )
        guard !threadIds.isEmpty else { return [] }

        let threads = try ThreadRecord
            .filter(threadIds.contains(Column("id")))
            .order(Column("lastMessageDate").desc, Column("id").desc)
            .fetchAll(db)
        return try ThreadQuery.summaries(forThreads: threads, db: db)
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
        let sql = """
            SELECT DISTINCT message.id FROM message
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
