import Foundation
import GRDB
import OtegamiCore

/// Maintains `messageSearchIndex`, the FTS5 (trigram, contentless) full-text
/// index `SearchQuery` reads (M7). This is the single place the tokenizer
/// name and the contentless upsert mechanics live (plan: "tokenizer 名は
/// FTSIndexer 内の定数に一点集約") — every write to `messageSearchIndex` in the
/// whole codebase goes through this type, never raw SQL elsewhere.
///
/// Every function here takes an already-open `Database` and is meant to run
/// inside the same write transaction as whatever changed `message`/
/// `messageBody` in the first place — envelope sync (`AccountSyncer.upsert`),
/// body fetch (`BodyFetcher.fetchBody`), or a message deletion (mailbox
/// resync wipe, thread delete, account delete) — the same convention
/// `ThreadAssigner` already uses for `thread`'s aggregates, so the index
/// never drifts from what's actually stored.
public enum FTSIndexer {
    /// The FTS5 tokenizer `messageSearchIndex` is built with (`AppDatabase`
    /// v7's `CREATE VIRTUAL TABLE`). Centralized here so a future tokenizer
    /// change is a one-line edit followed by a migration that drops/
    /// recreates the table and reindexes — not a change scattered across
    /// every call site that happens to build a MATCH query.
    public static let tokenizerName = "trigram"

    /// `message.fromText`'s plain-text rendering of a `From:` address list:
    /// each address as `EmailAddress.description` ("Name <address>", or
    /// just "address" with no display name), space-joined. Used both to
    /// populate `message.fromText` (`AccountSyncer.upsert`, and this
    /// migration's backfill) and as `messageSearchIndex.fromText`'s input —
    /// one function, so the two never disagree about what "the sender's
    /// searchable text" means.
    public static func composeFromText(_ addresses: [EmailAddress]) -> String {
        addresses.map(\.description).joined(separator: " ")
    }

    /// Deletes then reinserts one message's row in `messageSearchIndex`.
    /// Unconditional delete-then-insert (not an SQL `UPDATE`) per the plan
    /// ("更新は delete+insert"): `contentless_delete=1` (set at table
    /// creation) makes the delete side just `DELETE FROM messageSearchIndex
    /// WHERE rowid = ?` — no need to already know the row's previous
    /// subject/body/from text, unlike a plain contentless (`content=''`,
    /// no `contentless_delete`) table, which would require passing the old
    /// column values to its special two-argument delete command. Empty
    /// strings (not `NULL`) are stored for absent text so a later `MATCH`
    /// against that column reliably finds nothing rather than erroring.
    public static func upsert(
        messageId: Int64,
        subject: String?,
        plainText: String?,
        fromText: String?,
        db: Database
    ) throws {
        try delete(messageId: messageId, db: db)
        try db.execute(
            sql: "INSERT INTO messageSearchIndex(rowid, subject, plainText, fromText) VALUES (?, ?, ?, ?)",
            arguments: [messageId, subject ?? "", plainText ?? "", fromText ?? ""]
        )
    }

    /// Removes one message's row from the index (e.g. the message itself
    /// was deleted). A no-op, not an error, if the row isn't currently
    /// indexed — `contentless_delete=1` tables tolerate deleting a rowid
    /// that was never inserted, which matters for `upsert`'s unconditional
    /// delete-before-insert on a message that's never been indexed before.
    public static func delete(messageId: Int64, db: Database) throws {
        try db.execute(sql: "DELETE FROM messageSearchIndex WHERE rowid = ?", arguments: [messageId])
    }

    /// Bulk form of ``delete(messageId:db:)`` for the mailbox-wipe/account-
    /// delete paths that remove many messages in one transaction (a mailbox
    /// resync on a `uidValidity` change, `AppEnvironment.deleteAccount`) —
    /// one `DELETE ... WHERE rowid IN (...)` instead of N round trips.
    /// A no-op for an empty list (SQLite would otherwise choke on
    /// `IN ()`).
    public static func deleteAll(messageIds: [Int64], db: Database) throws {
        guard !messageIds.isEmpty else { return }
        let placeholders = messageIds.map { _ in "?" }.joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM messageSearchIndex WHERE rowid IN (\(placeholders))",
            arguments: StatementArguments(messageIds)
        )
    }

    /// Re-derives one message's indexed text straight from the database
    /// (`message.subject`/`.fromText`, `messageBody.plainText` if a body
    /// has been fetched yet) and upserts it. What every live call site
    /// (`AccountSyncer.upsert`, `BodyFetcher.fetchBody`) and the v7 backfill
    /// call, instead of each threading subject/plainText/fromText through
    /// by hand — so a resync that hasn't touched the body yet doesn't
    /// accidentally blow away a previously-indexed `plainText` (reading it
    /// back from `messageBody` here means there's nothing to blow away:
    /// whatever's actually stored is what gets reindexed). Deletes the
    /// index row instead if `messageId` no longer has a `message` row
    /// (defensive — every real deletion path calls `delete`/`deleteAll`
    /// directly, so this branch shouldn't normally be reached).
    public static func reindex(messageId: Int64, db: Database) throws {
        guard let message = try MessageRecord.fetchOne(db, key: messageId) else {
            try delete(messageId: messageId, db: db)
            return
        }
        let plainText = try MessageBodyRecord.fetchOne(db, key: messageId)?.plainText
        try upsert(
            messageId: messageId,
            subject: message.subject,
            plainText: plainText,
            fromText: message.fromText ?? composeFromText(message.fromAddresses),
            db: db
        )
    }

    /// Indexes every message that doesn't yet have a `messageSearchIndex`
    /// row. The v7 migration already backfills every message that existed
    /// at the moment a pre-M7 database upgrades, and every message inserted
    /// afterward is indexed live — so in normal operation this finds
    /// nothing and is effectively free (one `NOT EXISTS` scan). Kept as a
    /// defensive, idempotent self-heal `AppEnvironment` also runs once at
    /// startup (plan: "起動時に未 index メッセージを一括投入") in case some future
    /// code path ever inserts a `message` row without going through
    /// `AccountSyncer.upsert`.
    public static func backfillIfNeeded(db: Database) throws {
        let pendingIds = try Int64.fetchAll(
            db,
            sql: """
                SELECT message.id FROM message
                WHERE NOT EXISTS (
                    SELECT 1 FROM messageSearchIndex WHERE messageSearchIndex.rowid = message.id
                )
                """
        )
        for messageId in pendingIds {
            try reindex(messageId: messageId, db: db)
        }
    }
}
