import Foundation
import GRDB
import OtegamiCore

/// The app's local GRDB database: schema migrations, and the single
/// `DatabaseWriter` every DAO/query in `OtegamiStore` (and `SyncEngine`
/// above it) reads and writes through.
///
/// Production code should go through ``makeShared()``, which places the
/// database file under Application Support. Tests use ``makeInMemory()``
/// (a `DatabaseQueue`, since `DatabasePool` requires a real file for its
/// WAL/mmap machinery) so migrations and queries can be exercised without
/// touching disk.
public final class AppDatabase: Sendable {
    public let dbWriter: any DatabaseWriter

    /// Wraps an already-configured `DatabaseWriter` and runs migrations on
    /// it. Prefer ``makeShared()``/``makeInMemory()`` unless a test needs a
    /// custom writer (e.g. one with a `ValueObservation` scheduler
    /// override).
    public init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try Self.migrator.migrate(dbWriter)
    }

    /// The shared on-disk database, at
    /// `<container>/otegami/otegami.sqlite`.
    ///
    /// `appGroupIdentifier`, when non-`nil` and a container for it actually
    /// exists, places the database in that App Group's shared container
    /// instead of this process's own Application Support directory (M9:
    /// lets the `NotificationService` Extension open the same database —
    /// read-only in practice, since it only ever looks up an
    /// `AccountRecord` — as a concurrent `DatabasePool`/WAL reader; SQLite's
    /// WAL mode supports exactly this multi-process read pattern). Falls
    /// back to the pre-M9 Application Support location when `nil` or the
    /// container can't be resolved (no App Group entitlement configured —
    /// true for `swift test`, previews, and any target that never opted
    /// in), so this stays backward compatible for every caller that
    /// doesn't pass one.
    public static func makeShared(appGroupIdentifier: String? = nil) throws -> AppDatabase {
        let directory = try sharedDirectory(appGroupIdentifier: appGroupIdentifier)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("otegami.sqlite")
        let dbPool = try DatabasePool(path: url.path, configuration: makeConfiguration())
        return try AppDatabase(dbPool)
    }

    private static func sharedDirectory(appGroupIdentifier: String?) throws -> URL {
        if let appGroupIdentifier, !appGroupIdentifier.isEmpty,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return container.appendingPathComponent("otegami", isDirectory: true)
        }
        return try applicationSupportDirectory()
    }

    /// An in-memory database (no file on disk), for tests and previews.
    public static func makeInMemory() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue(configuration: makeConfiguration())
        return try AppDatabase(dbQueue)
    }

    private static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("otegami", isDirectory: true)
    }

    private static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return configuration
    }
}

extension AppDatabase {
    /// v1: `account` / `mailbox` / `message` / `messageReference` are what
    /// M1 (this migration's original purpose) actually reads and writes.
    /// `messageBody` / `attachment` / `thread` / `opQueue` and the FTS5
    /// index are defined now (so later milestones don't need a schema
    /// migration just to add a table the plan already specified) but stay
    /// empty until M2+.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
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
        migrator.registerMigration("v2") { db in
            try db.alter(table: "message") { t in
                t.add(column: "snippet", .text)
            }
        }

        // v3 (M3): exponential backoff between `opQueue` replay attempts
        // needs a "not eligible again until" timestamp per row —
        // `attempts` alone can't express *when* the next retry is allowed,
        // only how many have happened so far.
        migrator.registerMigration("v3") { db in
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
        migrator.registerMigration("v4") { db in
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
        migrator.registerMigration("v5") { db in
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
        migrator.registerMigration("v6") { db in
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
        migrator.registerMigration("v7") { db in
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
        migrator.registerMigration("v8") { db in
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
        migrator.registerMigration("v9") { db in
            try db.create(index: "thread_on_lastMessageDate", on: "thread", columns: ["lastMessageDate"])
            try db.create(index: "message_on_threadId_mailboxId", on: "message", columns: ["threadId", "mailboxId"])
            try db.create(index: "message_on_mailboxId_flagsRaw", on: "message", columns: ["mailboxId", "flagsRaw"])
        }

        // v10 (M10): local draft saving. `draftMessage` deliberately mirrors
        // `outboxMessage`'s shape but stays a separate table — see
        // `DraftMessageRecord`'s doc comment for why ("a draft must never
        // accidentally be picked up and sent").
        migrator.registerMigration("v10") { db in
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

        // v11 (iCloud account sync): `account.updatedAt` — see
        // `AccountRecord.updatedAt`'s doc comment. Added nullable (SQLite
        // `ALTER TABLE ADD COLUMN` can't express "default to another
        // column's value") and immediately backfilled from `createdAt`,
        // the same two-step pattern v7 used for `message.fromText`.
        migrator.registerMigration("v11") { db in
            try db.alter(table: "account") { t in
                t.add(column: "updatedAt", .datetime)
            }
            try db.execute(sql: "UPDATE account SET updatedAt = createdAt WHERE updatedAt IS NULL")
        }

        // v12: per-mailbox sync failure visibility (`docs/qa-findings.md`'s
        // "部分同期失敗の UI 可視化" follow-up). `AccountSyncer`'s per-mailbox
        // `do`/`catch` used to swallow one mailbox's sync failure entirely
        // (`continue`, no record anywhere) so the rest of the account's
        // mailboxes weren't blocked — see `MailboxRecord.lastSyncError`'s
        // doc comment for the full rationale. Both columns nullable, same
        // "record it, clear it on success" shape `opQueue.lastError` already
        // uses.
        migrator.registerMigration("v12") { db in
            try db.alter(table: "mailbox") { t in
                t.add(column: "lastSyncError", .text)
                t.add(column: "lastSyncErrorAt", .datetime)
            }
        }

        // v13 (account edit UI): account-level sync failure visibility —
        // see `AccountRecord.lastSyncError`'s doc comment for why this is a
        // separate column from v12's mailbox-scoped one (a connect-level
        // failure, e.g. a wrong password after editing an account, happens
        // *before* any mailbox is even selected).
        migrator.registerMigration("v13") { db in
            try db.alter(table: "account") { t in
                t.add(column: "lastSyncError", .text)
                t.add(column: "lastSyncErrorAt", .datetime)
            }
        }

        // v14: Drafts IMAP sync + draft attachments. `draftMessage` gains a
        // "known server copy" reference (`serverMailboxId`/`serverUid`/
        // `serverUidValidity`) — set once a local draft has been `APPEND`ed
        // to the account's Drafts mailbox (`OpQueueKind.saveDraft`'s replay),
        // and carried forward as "the old copy to replace" when a
        // server-origin draft is edited and re-saved (`ComposerView`'s
        // `.serverDraft` load path). `serverMailboxId` references `mailbox`
        // with `onDelete: .setNull` (not `.cascade`) — losing the account's
        // Drafts mailbox record (e.g. re-synced with a new `MailboxRecord`
        // id after some server-side reshuffle) shouldn't take the draft's
        // text down with it, only its "this is where the server copy lives"
        // pointer.
        //
        // `draftAttachment` mirrors `outboxAttachment`'s shape exactly (same
        // "bytes already staged on disk before the row exists" contract —
        // see `OutboxAttachmentRecord`'s doc comment) for the `ComposerView
        // .saveDraft()` / `OpQueueProcessor`'s `.saveDraft` replay path.
        //
        // `outboxMessage` gains the same three-column "known server Drafts
        // copy" reference as `draftMessage`, populated when `ComposerView
        // .send()` is invoked from a Composer that was resumed from a draft
        // (local or server-origin) — `OpQueueProcessor`'s `.send` replay
        // reads these to best-effort delete the now-redundant Drafts copy
        // once the message has actually been sent (`docs/roadmap.md`'s
        // "送信完了時に...下書きが残るのは典型的なバグ").
        migrator.registerMigration("v14") { db in
            try db.alter(table: "draftMessage") { t in
                t.add(column: "serverMailboxId", .integer).references("mailbox", onDelete: .setNull)
                t.add(column: "serverUid", .integer)
                t.add(column: "serverUidValidity", .integer)
            }

            try db.create(table: "draftAttachment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("draftMessageId", .integer).notNull()
                    .indexed()
                    .references("draftMessage", onDelete: .cascade)
                t.column("filename", .text).notNull()
                t.column("mimeType", .text).notNull()
                t.column("localPath", .text).notNull()
                t.column("size", .integer).notNull().defaults(to: 0)
            }

            try db.alter(table: "outboxMessage") { t in
                t.add(column: "draftServerMailboxId", .integer).references("mailbox", onDelete: .setNull)
                t.add(column: "draftServerUid", .integer)
                t.add(column: "draftServerUidValidity", .integer)
            }
        }

        // v15 (on-device translation engine, docs/translation.md):
        // `message.detectedLanguage` is a BCP-47 code (e.g. `"en"`, `"ja"`)
        // written by `SyncEngine.BodyFetcher` right after a body fetch, via
        // `MessageLanguageDetector` (`NLLanguageRecognizer` — no LLM
        // involved, see that type's doc comment for why). Nullable: `nil`
        // until the body has been fetched at least once (like `snippet`),
        // and also `nil` when the recognizer isn't confident enough to
        // commit to a language for very short/ambiguous text.
        //
        // `messageTranslation` is `MessageTranslator`'s cache — one row per
        // *message*, not per (message, targetLanguage) pair, since this
        // app only ever translates a message in one direction (its
        // detected language, into whichever language the reply-drafting
        // flow needs, is never simultaneously cached both ways for the
        // same message). `paragraphs` is a JSON-encoded
        // `[TranslatedParagraph]` (GRDB's usual "`Codable` array property
        // stored as JSON in a `.blob` column" pattern — see
        // `MessageRecord.fromAddresses`), aligned 1:1 with
        // `ParagraphSplitter.split(_:)`'s output over the source text, so
        // 1i's "段落長押しでその段落だけ原文表示" can look up paragraph
        // *N*'s original text by index. `engineIdentifier` records which
        // `TranslationService` implementation produced this row (e.g.
        // `"foundation-models"`, `"fake"`) — `MessageTranslator` treats a
        // cached row from a different engine identifier as stale and
        // re-translates, so swapping engines (or, per the on-device
        // model's own versioning, a future "the model changed enough that
        // old translations should be invalidated" event tracked via this
        // same field) doesn't silently keep serving pre-change output.
        migrator.registerMigration("v15") { db in
            try db.alter(table: "message") { t in
                t.add(column: "detectedLanguage", .text)
            }

            try db.create(table: "messageTranslation") { t in
                t.column("messageId", .integer).notNull().primaryKey()
                    .references("message", onDelete: .cascade)
                t.column("sourceLanguage", .text).notNull()
                t.column("targetLanguage", .text).notNull()
                t.column("translatedText", .text).notNull()
                t.column("paragraphs", .blob).notNull()
                t.column("engineIdentifier", .text).notNull()
                t.column("translatedAt", .datetime).notNull()
            }
        }

        // v16 (ピン留め): `message.isPinnedLocal` is the single source of
        // truth this app orders by — always updated the moment a user pins/
        // unpins a message (`MessageListView`/`ThreadDetailView`'s pin
        // action), independent of whether IMAP `\Flagged` sync is on
        // (`PinSettingsStore.syncWithFlaggedKey`, default off per the design
        // decision: "既定はローカル独自のフラグ"). When that setting is on,
        // `AccountSyncer.upsert` additionally mirrors the server's current
        // `\Flagged` bit into this column on every resync (so another
        // client's flag change surfaces here too), and the pin-toggle action
        // itself also flips the IMAP flag via the existing `setFlags` opQueue
        // path — see `PinSettingsStore`'s doc comment for the full design.
        //
        // `thread.isPinned` is the OR-aggregate over its messages'
        // `isPinnedLocal` ("スレッド内の1通でもピン留めされたらそのスレッド自体が
        // 最上位に"), maintained by `ThreadAssigner.recomputeAggregates`
        // alongside `unreadCount`/`messageCount` — not a live join, so
        // `ThreadQuery`'s ordering can sort by it directly.
        migrator.registerMigration("v16") { db in
            try db.alter(table: "message") { t in
                t.add(column: "isPinnedLocal", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "thread") { t in
                t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "thread_on_isPinned_lastMessageDate", on: "thread", columns: ["isPinned", "lastMessageDate"])
        }

        // v17 (C8 テンプレート): reusable compose templates. Managed globally
        // (not per-account) with an *optional* per-template account scope —
        // `accountId == nil` means "available from every account's
        // Composer"; a non-nil value restricts it to that one account
        // (`t.column("accountId", .text)...references("account", onDelete:
        // .cascade)` — deleting an account quietly drops only *that*
        // account's own scoped templates, never a global one). This is the
        // "interpretation B" the plan called out as the more practical of
        // the two readings of "アカウントごとに設定できる" (per-template scope
        // vs. a per-account default template): a single flat list is far
        // simpler to build a settings CRUD screen and a Composer picker
        // around than two parallel concepts, while still satisfying the
        // literal requirement — most users will want the same signature-
        // style templates everywhere and occasionally one that only makes
        // sense from a specific (e.g. work) account.
        migrator.registerMigration("v17") { db in
            try db.create(table: "mailTemplate") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("subject", .text)
                t.column("body", .text).notNull()
                t.column("accountId", .text)
                    .indexed()
                    .references("account", onDelete: .cascade)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // v18 (新画面構成: 検索演算子 `to:`/`cc:`): plain-text mirrors of
        // `toAddresses`/`ccAddresses`, exactly mirroring v7's `fromText`
        // addition (see `MessageRecord.toText`/`.ccText`'s doc comment for
        // why `SearchQuery`'s new operator matching can't query the JSON
        // `.blob` address columns directly). Backfilled the same way v7
        // backfilled `fromText`.
        migrator.registerMigration("v18") { db in
            try db.alter(table: "message") { t in
                t.add(column: "toText", .text)
                t.add(column: "ccText", .text)
            }
            let messages = try MessageRecord.fetchAll(db)
            for var message in messages {
                message.toText = FTSIndexer.composeFromText(message.toAddresses)
                message.ccText = FTSIndexer.composeFromText(message.ccAddresses)
                try message.update(db, columns: [Column("toText"), Column("ccText")])
            }
        }

        // v19 (新画面構成: メール本文画面「…」メニューの「スレッドをミュート」):
        // see `ThreadRecord.isMuted`'s doc comment for what this flag does
        // (and, importantly, does not — push suppression) and why.
        migrator.registerMigration("v19") { db in
            try db.alter(table: "thread") { t in
                t.add(column: "isMuted", .boolean).notNull().defaults(to: false)
            }
        }

        // v20 (新画面構成: 検索履歴): the last N raw query strings a user
        // actually ran, most-recent-first, tappable to re-run
        // (`SearchHistoryQuery`/`SearchScreenView`). Deliberately its own
        // tiny table rather than reusing `mailTemplate`'s "flat list +
        // optional accountId scope" shape — search history has no per-
        // account scoping concept (a query searches across whichever scope
        // the search screen has selected at the time, independent of what
        // was selected when it was first typed) and needs `queryText` to be
        // unique so re-running an existing entry bumps its `updatedAt`
        // (moves it to the top) instead of accumulating duplicate rows.
        migrator.registerMigration("v20") { db in
            try db.create(table: "searchHistory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("queryText", .text).notNull().unique()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "searchHistory_on_updatedAt", on: "searchHistory", columns: ["updatedAt"])
        }

        // v21 (Gmail フォルダ名文字化け修正): `mailbox.displayPath` was meant
        // to hold RFC 3501 modified-UTF-7-decoded text (`MailboxInfo
        // .displayPath`'s doc comment always documented this), but the
        // decode step was never implemented until `ModifiedUTF7`/this
        // migration — every `displayPath` written before now is actually
        // the raw encoded path (e.g. Gmail's "[Gmail]/&MFkweTBmMG4w4TD8MOs-"
        // instead of "[Gmail]/すべてのメール"). Undetected during
        // development because dev/mailstack's Dovecot fixtures only ever
        // used plain-ASCII folder names — modified UTF-7 of pure ASCII text
        // is the identity transform, so `ModifiedUTF7.decode` silently
        // no-opped there and the bug only showed up against real Gmail
        // accounts (`docs/verify.md`'s Gmail フォルダ名文字化け entry).
        //
        // `path` (the raw IMAP identifier used in SELECT/FETCH) was never
        // wrong and needs no repair — only `displayPath` is recomputed
        // here, from `path`/`delimiter`, using the exact same logic
        // `MailCoreIMAPSession.mailboxInfo(from:)` now applies on every
        // future `listMailboxes()` pass (which would otherwise
        // self-heal this on the next successful sync anyway — see
        // `AccountSyncer.upsertMailboxes`'s unconditional `displayPath`
        // overwrite — but repairing it immediately means a user isn't
        // staring at mojibake folder names until their next sync
        // completes).
        migrator.registerMigration("v21") { db in
            let mailboxes = try MailboxRecord.fetchAll(db)
            for var mailbox in mailboxes {
                let decodedPath = ModifiedUTF7.decode(mailbox.path)
                let delimiter = mailbox.delimiter
                let displayPath: String
                if let delimiter, delimiter != "/" {
                    displayPath = decodedPath.replacingOccurrences(of: delimiter, with: "/")
                } else {
                    displayPath = decodedPath
                }
                guard displayPath != mailbox.displayPath else { continue }
                mailbox.displayPath = displayPath
                try mailbox.update(db, columns: [Column("displayPath")])
            }
        }

        // v22 (D「アカウントのラベル色を変更可能に」): nullable — see
        // `AccountRecord.labelColorKey`'s doc comment. Every pre-existing
        // row gets NULL (SQLite's default for a nullable column added via
        // `ALTER TABLE ... ADD COLUMN` with no `.defaults(to:)`), which
        // `OtegamiAccountColor.color(for:override:)` already treats as
        // "keep using the deterministic auto-assignment" — no backfill
        // needed.
        migrator.registerMigration("v22") { db in
            try db.alter(table: "account") { t in
                t.add(column: "labelColorKey", .text)
            }
        }

        // v23 (F「署名テンプレート」): see `SignatureTemplateRecord`'s doc
        // comment for why this is a separate table from `mailTemplate`
        // rather than an extension of it. `accountIds` is `.blob` for the
        // same reason `outboxMessage.toAddresses` is (`v1`'s migration) —
        // GRDB's Codable-record support JSON-encodes a plain Swift array
        // property to a BLOB column automatically.
        migrator.registerMigration("v23") { db in
            try db.create(table: "signatureTemplate") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("body", .text).notNull()
                t.column("accountIds", .blob).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // v24 (F「デフォルト署名（アカウントごと）」): nullable, `onDelete:
        // .setNull` so deleting a signature template automatically clears
        // it from every account that had it as their default — no manual
        // cleanup code needed at the deletion call site (`SyncEngine`'s
        // `.setNull` reliance mirrors `mailTemplate.accountId`'s existing
        // `onDelete: .cascade` pattern from v17, just with a different
        // action since an account's *default signature* going away should
        // leave the account itself intact, unlike a template that loses
        // its owning account). **Deliberately not synced via iCloud**
        // (`AccountCloudSync.CloudAccountSnapshot` has no
        // `defaultSignatureId` field) — `signatureTemplate.id` is a
        // device-local `AUTOINCREMENT` value with no cross-device meaning
        // (unlike `AccountRecord.id`, a UUID chosen once and treated as the
        // stable identity `docs/icloud-sync.md` syncs by), so syncing this
        // column as-is would point at an unrelated or nonexistent row on
        // another device. Syncing the signatures themselves is future work
        // this batch doesn't attempt (`docs/settings.md`'s F section notes
        // the scope decision).
        migrator.registerMigration("v24") { db in
            try db.alter(table: "account") { t in
                t.add(column: "defaultSignatureId", .integer)
                    .references("signatureTemplate", onDelete: .setNull)
            }
        }

        return migrator
    }
}
