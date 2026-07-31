import Foundation
import GRDB
import OtegamiCore

/// `AppDatabase.migrator`'s v1〜v10 registrations, split out of
/// `AppDatabase.swift` purely for file size (Phase 4 OtegamiKit内部整理).
///
/// **Ordering is load-bearing and must not change.** GRDB's
/// `DatabaseMigrator` applies migrations in the order `registerMigration`
/// was *called*, not identifier sort order (internally an `OrderedDictionary`
/// keyed by identifier, appended to on each call). `AppDatabase.migrator`
/// calls this file's `registerAppDatabaseMigrationsV1ToV10()` before the
/// v11〜v20/v21〜v30/v31〜v38 siblings, in that exact sequence — moving a
/// call between files, or reordering the four calls in `AppDatabase.swift`,
/// changes what already-migrated devices apply next. Each migration's
/// identifier string (`"v1"`, `"v2"`, ...) is likewise never to be renamed:
/// GRDB tracks applied migrations by identifier, so renaming one makes a
/// device that already applied it re-run under the new name.
extension DatabaseMigrator {
    /// v1: `account` / `mailbox` / `message` / `messageReference` are what
    /// M1 (this migration's original purpose) actually reads and writes.
    /// `messageBody` / `attachment` / `thread` / `opQueue` and the FTS5
    /// index are defined now (so later milestones don't need a schema
    /// migration just to add a table the plan already specified) but stay
    /// empty until M2+.
    mutating func registerAppDatabaseMigrationsV1ToV10() {
        registerMigration("v1") { db in
            try db.create(table: "account") { t in
                t.column("id", .text).primaryKey()
                t.column("displayName", .text).notNull()
                t.column("email", .text).notNull()
                t.column("authType", .text).notNull()
                t.column("imapHost", .text).notNull()
                t.column("imapPort", .integer).notNull()
                t.column("imapSecurity", .text).notNull()
                t.column("imapAllowsInsecureTLS", .boolean).notNull().defaults(to: false)
                t.column("imapUsername", .text).notNull()
                t.column("smtpHost", .text)
                t.column("smtpPort", .integer)
                t.column("smtpSecurity", .text)
                t.column("smtpAllowsInsecureTLS", .boolean).notNull().defaults(to: false)
                t.column("smtpUsername", .text)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "mailbox") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .text).notNull()
                    .indexed()
                    .references("account", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("displayPath", .text).notNull()
                t.column("delimiter", .text)
                t.column("role", .text).notNull()
                t.column("attributesRaw", .integer).notNull().defaults(to: 0)
                t.column("uidValidity", .integer).notNull().defaults(to: 0)
                t.column("uidNext", .integer).notNull().defaults(to: 0)
                t.column("highestModSeq", .integer).notNull().defaults(to: 0)
                t.column("messageCount", .integer).notNull().defaults(to: 0)
                t.column("lastSyncedAt", .datetime)
                t.uniqueKey(["accountId", "path"])
            }

            // Created before `message` (rather than down near `attachment`,
            // where it's grouped by "M4+ schema") because `message.threadId`
            // references it — SQLite/GRDB requires a foreign key's target
            // table to already exist at `CREATE TABLE` time.
            try db.create(table: "thread") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .text).notNull()
                    .indexed()
                    .references("account", onDelete: .cascade)
                t.column("normalizedSubject", .text)
                t.column("lastMessageDate", .datetime)
                t.column("messageCount", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "message") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("mailboxId", .integer).notNull()
                    .indexed()
                    .references("mailbox", onDelete: .cascade)
                t.column("uid", .integer).notNull()
                t.column("messageId", .text)
                t.column("inReplyTo", .text)
                t.column("subject", .text)
                t.column("normalizedSubject", .text)
                t.column("fromAddresses", .blob).notNull()
                t.column("toAddresses", .blob).notNull()
                t.column("ccAddresses", .blob).notNull()
                t.column("bccAddresses", .blob).notNull()
                t.column("replyToAddresses", .blob).notNull()
                t.column("date", .datetime)
                t.column("internalDate", .datetime).notNull()
                t.column("flagsRaw", .integer).notNull().defaults(to: 0)
                t.column("size", .integer).notNull().defaults(to: 0)
                t.column("gmailThreadId", .integer)
                t.column("gmailMessageId", .integer)
                t.column("hasAttachments", .boolean).notNull().defaults(to: false)
                t.column("threadId", .integer)
                    .indexed()
                    .references("thread", onDelete: .setNull)
                t.column("bodyState", .text).notNull().defaults(to: MessageBodyState.notFetched.rawValue)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["mailboxId", "uid"])
            }
            try db.create(index: "message_on_messageId", on: "message", columns: ["messageId"])
            try db.create(index: "message_on_internalDate", on: "message", columns: ["internalDate"])

            try db.create(table: "messageReference") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("messageId", .integer).notNull()
                    .indexed()
                    .references("message", onDelete: .cascade)
                t.column("referenceValue", .text).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(index: "messageReference_on_referenceValue", on: "messageReference", columns: ["referenceValue"])

            try db.create(table: "messageBody") { t in
                t.column("messageId", .integer).notNull().primaryKey()
                    .references("message", onDelete: .cascade)
                t.column("plainText", .text)
                t.column("html", .text)
                t.column("fetchedAt", .datetime)
            }

            try db.create(table: "attachment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("messageId", .integer).notNull()
                    .indexed()
                    .references("message", onDelete: .cascade)
                t.column("partId", .text).notNull()
                t.column("filename", .text)
                t.column("mimeType", .text).notNull()
                t.column("mimeSubtype", .text).notNull()
                t.column("contentId", .text)
                t.column("isInline", .boolean).notNull().defaults(to: false)
                t.column("size", .integer).notNull().defaults(to: 0)
                t.column("localPath", .text)
            }

            try db.create(table: "opQueue") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .text).notNull()
                    .indexed()
                    .references("account", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
            }

            // trigram: SQLite's built-in tokenizer (no extra dependency),
            // matches substrings >=3 characters — including Japanese, which
            // has no word-boundary whitespace for unicode61 to split on.
            // Shorter queries fall back to LIKE (see the plan's FTS5
            // section); that fallback lives in `FTSIndexer` (M7), not here.
            try db.create(virtualTable: "messageSearchIndex", using: FTS5()) { t in
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("subject")
                t.column("plainText")
            }
        }

        // v2 (M2): a short plain-text preview for the message list row,
        // populated by `SyncEngine.BodyFetcher` alongside the body itself
        // (`SnippetBuilder`) — kept on `message` rather than derived from
        // `messageBody` at read time so `MessageQuery`'s list observation
        // doesn't need to join against `messageBody` just to render a row.
        registerMigration("v2") { db in
            try db.alter(table: "message") { t in
                t.add(column: "snippet", .text)
            }
        }

        // v3 (M3): exponential backoff between `opQueue` replay attempts
        // needs a "not eligible again until" timestamp per row —
        // `attempts` alone can't express *when* the next retry is allowed,
        // only how many have happened so far.
        registerMigration("v3") { db in
            try db.alter(table: "opQueue") { t in
                t.add(column: "nextRetryAt", .datetime)
            }
        }

        // v4 (M4): threading. `thread.unreadCount` is maintained by
        // `ThreadAssigner.recomputeAggregates` (app logic, not a trigger —
        // see the plan's "トリガでなくアプリロジックで" note) so `ThreadRow`
        // can show a badge without a live join. The two new indexes back
        // `ThreadAssigner`'s incremental lookups: `gmailThreadId` for the
        // Gmail-priority pass (M6, but implemented now per the plan), and
        // `normalizedSubject` for the subject-fallback candidate query —
        // both filter the whole `message` table via `mailbox.accountId`
        // otherwise.
        registerMigration("v4") { db in
            try db.alter(table: "thread") { t in
                t.add(column: "unreadCount", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "message_on_normalizedSubject", on: "message", columns: ["normalizedSubject"])
            try db.create(index: "message_on_gmailThreadId", on: "message", columns: ["gmailThreadId"])
        }

        // v5 (M5): Compose/Reply/SMTP + Outbox. `account.kind` lets
        // `OpQueueProcessor`'s `.send` replay branch on Gmail (M6) without a
        // later migration; `outboxMessage` is the Composer's local
        // "still sending" record (see its doc comment) that `OpQueueKind
        // .send`'s payload references by id.
        registerMigration("v5") { db in
            try db.alter(table: "account") { t in
                t.add(column: "kind", .text).notNull().defaults(to: AccountKind.generic.rawValue)
            }

            try db.create(table: "outboxMessage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .text).notNull()
                    .indexed()
                    .references("account", onDelete: .cascade)
                t.column("toAddresses", .blob).notNull()
                t.column("ccAddresses", .blob).notNull()
                t.column("bccAddresses", .blob).notNull()
                t.column("subject", .text).notNull()
                t.column("plainTextBody", .text).notNull()
                t.column("inReplyToMessageId", .text)
                t.column("references", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        // v6 (M6): Gmail OAuth. `needsReauth` is the persisted form of
        // `GoogleOAuth.TokenStoreError.reauthenticationRequired` — see
        // `AccountRecord.needsReauth`'s doc comment. A plain boolean
        // column (not, say, a richer "auth status" enum) since it's the
        // only OAuth-specific state that needs to survive a relaunch;
        // everything else (cached access token, refresh token) lives in
        // `TokenStore`/Keychain, not this table.
        registerMigration("v6") { db in
            try db.alter(table: "account") { t in
                t.add(column: "needsReauth", .boolean).notNull().defaults(to: false)
            }
        }

        // v7 (M7): full-text search. `message.fromText` is a plain-text
        // "Name <address> ..." rendering of `fromAddresses`
        // (`FTSIndexer.composeFromText`) kept as its own column —
        // `fromAddresses` itself is JSON in a `.blob` column, which SQLite's
        // `LIKE` can't usefully match against — so both the FTS index and
        // `SearchQuery`'s short-query (<3 characters) `LIKE` fallback have
        // plain text to search.
        //
        // `messageSearchIndex` is dropped and recreated rather than altered
        // in place because v1's definition is missing two things GRDB's
        // `FTS5TableDefinition` has no property for, so they have to be
        // written as raw SQL: `content=''` (contentless — nothing stored
        // outside the index itself, keeping the table small) and
        // `contentless_delete=1` (SQLite 3.43+; makes a plain `DELETE FROM
        // messageSearchIndex WHERE rowid = ?` legal, instead of requiring
        // every column's *old* value just to remove one row — see
        // `FTSIndexer`'s doc comment for the upsert-via-delete-then-insert
        // this enables). Dropping unconditionally is safe: v1's table was
        // schema-only and never populated (M7 is the milestone that starts
        // writing to it), so there's no existing index data to lose.
        registerMigration("v7") { db in
            try db.alter(table: "message") { t in
                t.add(column: "fromText", .text)
            }

            try db.execute(sql: "DROP TABLE messageSearchIndex")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE messageSearchIndex USING fts5(
                    subject,
                    plainText,
                    fromText,
                    tokenize = '\(FTSIndexer.tokenizerName)',
                    content = '',
                    contentless_delete = 1
                )
                """)

            // Backfill (plan: "既存 DB の backfill"): populates
            // `message.fromText` for rows that predate this migration, then
            // indexes every message that existed before M7. New rows after
            // this point are indexed live by `AccountSyncer.upsert`/
            // `BodyFetcher.fetchBody` (both call `FTSIndexer.reindex`), so
            // this loop only ever does real work once — the moment a
            // pre-M7 database migrates through this step.
            let messages = try MessageRecord.fetchAll(db)
            for var message in messages {
                guard let messageId = message.id else { continue }
                message.fromText = FTSIndexer.composeFromText(message.fromAddresses)
                try message.update(db, columns: [Column("fromText")])
                try FTSIndexer.reindex(messageId: messageId, db: db)
            }
        }

        // v8 (M8): attachment send support. `outboxAttachment` mirrors
        // `attachment`'s shape loosely, but for the *outgoing* side: rows
        // here always have data on disk already (`localPath` is `NOT NULL`,
        // unlike `attachment.localPath` which starts `NULL` until fetched)
        // — `ComposerView.send` copies each picked file into
        // `<Application Support>/otegami/Outbox/<outboxMessageId>/<filename>`
        // (plan: "送信前に Application Support/Outbox/ へコピーして安定パス化")
        // before ever inserting a row, precisely so a security-scoped
        // picker URL going stale after the picker session ends can't orphan
        // a queued send. `OpQueueProcessor`'s `.send` replay reads these
        // rows (and the bytes at `localPath`) at replay time, the same
        // "rebuild from the row, not a pre-built snapshot" pattern
        // `outboxMessage` itself already uses for the rest of the draft.
        registerMigration("v8") { db in
            try db.create(table: "outboxAttachment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("outboxMessageId", .integer).notNull()
                    .indexed()
                    .references("outboxMessage", onDelete: .cascade)
                t.column("filename", .text).notNull()
                t.column("mimeType", .text).notNull()
                t.column("localPath", .text).notNull()
                t.column("size", .integer).notNull().defaults(to: 0)
            }
        }

        // v9 (M10): performance indexes, added after seeding a 100k-message
        // synthetic mailstack showed the unified inbox / unread-count
        // queries doing full scans without them (docs/performance.md has
        // the before/after numbers). `thread_on_lastMessageDate` lets
        // `ThreadQuery`'s EXISTS-based rewrite walk `thread` in
        // already-sorted order and stop at `LIMIT` instead of sorting every
        // matching row; `message_on_threadId_mailboxId` backs that query's
        // per-thread `EXISTS (... message.threadId = ? AND message.mailboxId
        // = ?)` probe; `message_on_mailboxId_flagsRaw` backs the new
        // per-mailbox/unified-inbox unread-count queries (`MessageQuery
        // .unreadCounts`/`unifiedInboxUnreadCount`), which filter on both
        // columns together.
        registerMigration("v9") { db in
            try db.create(index: "thread_on_lastMessageDate", on: "thread", columns: ["lastMessageDate"])
            try db.create(index: "message_on_threadId_mailboxId", on: "message", columns: ["threadId", "mailboxId"])
            try db.create(index: "message_on_mailboxId_flagsRaw", on: "message", columns: ["mailboxId", "flagsRaw"])
        }

        // v10 (M10): local draft saving. `draftMessage` deliberately mirrors
        // `outboxMessage`'s shape but stays a separate table — see
        // `DraftMessageRecord`'s doc comment for why ("a draft must never
        // accidentally be picked up and sent").
        registerMigration("v10") { db in
            try db.create(table: "draftMessage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .text).notNull()
                    .indexed()
                    .references("account", onDelete: .cascade)
                t.column("toAddresses", .blob).notNull()
                t.column("ccAddresses", .blob).notNull()
                t.column("subject", .text).notNull()
                t.column("plainTextBody", .text).notNull()
                t.column("inReplyToMessageId", .text)
                t.column("references", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
    }
}
