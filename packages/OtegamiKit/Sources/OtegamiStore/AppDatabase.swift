import Foundation
import GRDB
import OtegamiCore
import os

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
        Self.logStaleMessageBodyRenderVersionCount(dbWriter)
    }

    /// 2026-07-30 (v36の`messageBody.renderVersion`導入時): 起動のたびに
    /// 「まだ古い版数のまま=次に開いたら遅延再フェッチされる、本文キャッ
    /// シュがどれだけ残っているか」を件数だけ (本文は一切出さない、F15の
    /// 趣旨) notice ログへ — 一括再取得はしない設計なので、この件数は
    /// ユーザーが実際にそのメッセージを開くまでゆっくり減っていく。運用側
    /// が「まだ大量に残っているのに翻訳/表示の不具合報告が来る」ような
    /// ギャップに気づけるようにするためのもの。失敗しても起動を止めない。
    private static func logStaleMessageBodyRenderVersionCount(_ dbWriter: any DatabaseWriter) {
        guard let count = try? dbWriter.read({ db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageBody WHERE renderVersion < ?", arguments: [MessageBodyRecord.currentRenderVersion])
        }) else { return }
        guard count > 0 else { return }
        Logger(subsystem: "com.mtkg.otegami", category: "AppDatabase")
            .notice("messageBody: \(count, privacy: .public) row(s) still at a stale renderVersion (current=\(MessageBodyRecord.currentRenderVersion, privacy: .public)), pending lazy re-fetch on next open")
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
        let (directory, isSharedContainer) = try sharedDirectory(appGroupIdentifier: appGroupIdentifier)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("otegami.sqlite")
        // Task #192 (実機クラッシュ 0xDEAD10CC): only a database that actually
        // lives in the App Group's shared container is at risk of iOS
        // killing this process for holding a lock on it while suspended —
        // see `makeConfiguration(observesSuspensionNotifications:)`'s doc
        // comment. `isSharedContainer` is `false` on macOS (no App Group
        // entitlement — `OtegamiAppGroup.identifier` always returns `nil`
        // there) and for every `swift test`/preview target, so this stays a
        // no-op everywhere except the real iOS app and the `NotificationService`
        // Extension, both of which open this exact same shared file.
        let dbPool = try DatabasePool(path: url.path, configuration: makeConfiguration(observesSuspensionNotifications: isSharedContainer))
        return try AppDatabase(dbPool)
    }

    private static func sharedDirectory(appGroupIdentifier: String?) throws -> (directory: URL, isSharedContainer: Bool) {
        if let appGroupIdentifier, !appGroupIdentifier.isEmpty,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return (container.appendingPathComponent("otegami", isDirectory: true), true)
        }
        return (try applicationSupportDirectory(), false)
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

    /// - Parameter observesSuspensionNotifications: Task #192 (実機クラッシュ
    ///   解析: `EXC_CRASH`/`SIGKILL`, `RUNNINGBOARD` termination code
    ///   `3735883980` = `0xDEAD10CC` — iOS's dedicated code for "killed this
    ///   app for holding a file/SQLite lock while suspended in the
    ///   background"). GRDB's official fix (`Documentation.docc
    ///   /DatabaseSharing.md`'s "How to limit the 0xDEAD10CC exception"
    ///   section, verified against the exact GRDB 7.11.1 tag this project
    ///   pins in `Package.resolved` — not assumed from memory): set
    ///   ``Configuration/observesSuspensionNotifications`` so this
    ///   `DatabasePool` starts listening for ``Database/suspendNotification``/
    ///   ``Database/resumeNotification``. Once suspended, GRDB refuses to
    ///   acquire any *new* SQLite lock — the exact thing that can trigger
    ///   `0xDEAD10CC` — and instead fails the access with
    ///   `SQLITE_INTERRUPT`/`SQLITE_ABORT` (`DatabaseError.isInterruptionError`).
    ///   `AppEnvironment.suspendSharedDatabaseIfNeeded()`/
    ///   `.resumeSharedDatabaseIfNeeded()` (iOS-only — macOS has no shared
    ///   App Group container to race a background suspend over, see
    ///   `OtegamiAppGroup.identifier`'s doc comment) post those two
    ///   notifications from `OtegamiApp.handleScenePhaseChange`;
    ///   `SyncEngine`'s `AccountSyncer`/`OpQueueProcessor` treat the
    ///   resulting interruption errors as "try again once resumed", not a
    ///   real sync failure — see `DatabaseSuspensionSupport
    ///   .isSuspensionError(_:)`'s doc comment. Defaults to `false` so
    ///   `makeInMemory()` (tests/previews, and every target with no App
    ///   Group entitlement) never pays for observers it has no use for.
    private static func makeConfiguration(observesSuspensionNotifications: Bool = false) -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.observesSuspensionNotifications = observesSuspensionNotifications
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

        // v12: per-mailbox sync failure visibility (the "部分同期失敗の
        // UI 可視化" follow-up). `AccountSyncer`'s per-mailbox
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
        // action). `AccountSyncer.upsert` additionally mirrors the server's
        // current `\Flagged` bit into this column on every resync (so
        // another client's flag change surfaces here too), and the
        // pin-toggle action itself also flips the IMAP flag via the
        // existing `setFlags` opQueue path.
        //
        // Task #212 (実機フィードバック「サーバのフラグと連動は設定から
        // 消して、内部的には連動 on として動いてほしい」): this used to be
        // opt-in via a `PinSettingsStore.syncWithFlaggedKey` toggle (default
        // off — "既定はローカル独自のフラグ"); that toggle and its
        // Settings-UI row were removed, and the sync above is now
        // unconditional.
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
        // Raw `Row`/SQL, not `MailboxRecord.fetchAll(db)`/`.update(db)` —
        // deliberately: a migration runs against the schema *as it existed
        // at that version*, but a `FetchableRecord`/`MutablePersistableRecord`
        // conformance always decodes/writes using *today's* Swift struct
        // shape, columns added by any later migration included. `mailbox`
        // gained `isHidden` in v26 (after this one), and `MailboxRecord`
        // already declares that property in current code — decoding via
        // `MailboxRecord.fetchAll(db)` here would fail with "column not
        // found: isHidden" against a v21-stage table that hasn't run v26
        // yet, exactly the same "frozen schema vs. live struct" hazard
        // `v21RepairsDisplayPath` (`AppDatabaseTests.swift`) already
        // exercises for hand-inserted rows, now confirmed to bite a
        // *production* migration's own code too, not just a test's setup.
        migrator.registerMigration("v21") { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, path, delimiter, displayPath FROM mailbox")
            for row in rows {
                let id: Int64 = row["id"]
                let path: String = row["path"]
                let delimiter: String? = row["delimiter"]
                let currentDisplayPath: String = row["displayPath"]
                let decodedPath = ModifiedUTF7.decode(path)
                let displayPath: String
                if let delimiter, delimiter != "/" {
                    displayPath = decodedPath.replacingOccurrences(of: delimiter, with: "/")
                } else {
                    displayPath = decodedPath
                }
                guard displayPath != currentDisplayPath else { continue }
                try db.execute(sql: "UPDATE mailbox SET displayPath = ? WHERE id = ?", arguments: [displayPath, id])
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
        // its owning account). **This column itself is still deliberately
        // not synced via iCloud** (`AccountCloudSync.CloudAccountSnapshot`
        // has no `defaultSignatureId` field) — `signatureTemplate.id` stays
        // a device-local `AUTOINCREMENT` value with no cross-device meaning
        // even after v37 below (unlike `AccountRecord.id`, a UUID chosen
        // once and treated as the stable identity `docs/icloud-sync.md`
        // syncs by), so syncing this column as-is would still point at an
        // unrelated or nonexistent row on another device. **Update (Task
        // #186, v37 below)**: "Syncing the signatures themselves is future
        // work this batch doesn't attempt" — the deferral this comment used
        // to end on — is no longer true; `signatureTemplate`/`mailTemplate`
        // rows themselves (name/body/accountIds/subject) now sync via
        // `TemplateCloudSyncEngine`, keyed on the new `syncId` column v37
        // adds specifically because `id` can't serve that role. Only this
        // per-account *pointer* to a signature (as opposed to the signature
        // itself) remains unsynced.
        migrator.registerMigration("v24") { db in
            try db.alter(table: "account") { t in
                t.add(column: "defaultSignatureId", .integer)
                    .references("signatureTemplate", onDelete: .setNull)
            }
        }

        // v25 (アカウントの並び替え): `AccountRecord.sortOrder`'s doc comment
        // has the full picture. Added nullable-free with a `0` SQL default
        // (unlike, say, v22's `labelColorKey`, "0 for everyone" *is* the
        // right shared starting point here, not a per-row "unset" marker),
        // then immediately backfilled to a dense `0, 1, 2, ...` sequence in
        // `createdAt` order — "既存アカウントは現在の表示順 (createdAt 順) で
        // 初期化" — so this migration is a no-op for how any existing
        // install's account list actually looks the moment it runs.
        migrator.registerMigration("v25") { db in
            try db.alter(table: "account") { t in
                t.add(column: "sortOrder", .integer).notNull().defaults(to: 0)
            }
            let accounts = try AccountRecord.order(Column("createdAt")).fetchAll(db)
            for (index, var account) in accounts.enumerated() {
                account.sortOrder = index
                try account.update(db, columns: [Column("sortOrder")])
            }
        }

        // v26 (メールボックス単位の非表示): `MailboxRecord.isHidden`'s doc
        // comment has the full picture. `false` for every existing
        // mailbox — nothing changes visibility/sync scope for an existing
        // install until the user explicitly hides one via the new
        // per-account "メールボックスの表示設定" screen.
        migrator.registerMigration("v26") { db in
            try db.alter(table: "mailbox") { t in
                t.add(column: "isHidden", .boolean).notNull().defaults(to: false)
            }
        }

        // v27 (Task #52, Gmail アーカイブの定義): `GmailArchiveFilter`が
        // 「Gmail の All Mail のうち INBOX/Sent/Drafts と重複しないもの」を
        // 判定するたび `message.gmailMessageId` で自己結合するため、その
        // 列にインデックスを張る — `message_on_gmailThreadId` (v?, スレッド
        // 組み立て用) と同じ理由で、この列も既存の非インデックス列のままだと
        // フルスキャンになる規模 (All Mail は他のどのメールボックスより大きい)。
        migrator.registerMigration("v27") { db in
            try db.create(index: "message_on_gmailMessageId", on: "message", columns: ["gmailMessageId"])
        }

        // v28 (Task #66, カレンダー招待メール対応): `CalendarInviteResponseRecord`'s
        // doc comment has the full picture — one row per `message.id`
        // (`unique()`), replaced wholesale on every re-response rather than
        // accumulating history, so `MessageView`'s invite card can show
        // "すでに回答済み" the next time the same invite email is opened.
        // `onDelete: .cascade` mirrors `attachment.messageId`'s v1 shape:
        // this row is meaningless once its owning `message` row is gone
        // (deleted, or the account itself removed).
        migrator.registerMigration("v28") { db in
            try db.create(table: "calendarInviteResponse") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("messageId", .integer).notNull().unique().indexed()
                    .references("message", onDelete: .cascade)
                t.column("partStat", .text).notNull()
                t.column("respondedAt", .datetime).notNull()
            }
        }

        // v29 (検索画面再構成 Task #86: 検索画面の「保存済み」タブ): クエリ
        // 文字列 + フィルタ (`SearchFilterOption.rawValue`) + アカウント絞り
        // (`nil` = 全部) の組み合わせを、検索フィールドの星タップで明示的に
        // 保存する (`SavedSearchQuery`/`SavedSearchRecord`)。`searchHistory`
        // (v20、実行したクエリを自動記録) とは別テーブル — こちらは
        // 「ユーザーが選んで残した」ものだけが入る。`queryText`に`UNIQUE`を
        // 付けないのは v20 との意図的な違い: 同じクエリ文字列でもフィルタ/
        // アカウントが異なれば別の保存として共存できる必要があるため
        // (`SavedSearchQuery.toggle`のドキュメントコメント参照)。
        migrator.registerMigration("v29") { db in
            try db.create(table: "savedSearch") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("queryText", .text).notNull()
                t.column("filter", .text).notNull()
                t.column("accountId", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "savedSearch_on_createdAt", on: "savedSearch", columns: ["createdAt"])
        }

        // v30 (Task #124, 二重送信防止): `OutboxMessageRecord.sendStartedAt`
        // — `OpQueueProcessor`'s `.send` replay claims this column
        // (`NULL` → now) in one serialized `dbWriter.write` transaction
        // immediately before actually handing the message to SMTP, and
        // only proceeds if it won that claim. That makes a still-`NULL`
        // row the ground truth for "never attempted", and a non-`NULL` row
        // mean "some attempt already owns this send" — a second concurrent
        // `replay()` (or a resumed one after a crash mid-send) sees the
        // claim already taken and refuses to resend rather than risking a
        // duplicate delivery. `NULL` for every existing row: nothing
        // in-flight has actually started until a replay pass claims it.
        migrator.registerMigration("v30") { db in
            try db.alter(table: "outboxMessage") { t in
                t.add(column: "sendStartedAt", .datetime)
            }
        }

        // v31 (Task #154, 実機報告「ゴミ箱カテゴリに Gmail が2行出る」):
        // `MailboxRecord.roleIsAuthoritative`'s doc comment has the full
        // picture — `false` for every existing mailbox until the next sync
        // re-`upsertMailboxes`es it with a real value (same self-healing
        // shape as `role` itself, which this migration doesn't touch).
        migrator.registerMigration("v31") { db in
            try db.alter(table: "mailbox") { t in
                t.add(column: "roleIsAuthoritative", .boolean).notNull().defaults(to: false)
            }
        }

        // v32 (Task #156, #129のHTML送信配線): `OutboxMessageRecord.htmlBody`'s
        // doc comment has the full picture — `NULL` for every existing row
        // (nothing in-flight at migration time was composed with the rich
        // text editor's HTML rendering captured), non-`NULL` only for a row
        // `ComposerView.send()` writes from here on. No backfill needed:
        // an already-queued send with a `NULL` htmlBody just replays as the
        // plain `text/plain` message it always was (`OpQueueProcessor`'s
        // `.send` case passes `outbox.htmlBody` straight through to
        // `ComposeDraft.htmlBody`, which is optional).
        migrator.registerMigration("v32") { db in
            try db.alter(table: "outboxMessage") { t in
                t.add(column: "htmlBody", .text)
            }
        }

        // v33 (Task #161, #129/#156のフォローアップ「下書きの
        // htmlBody未対応」を解消): `DraftMessageRecord.htmlBody`'s doc
        // comment has the full picture — same "NULL for every existing
        // row, no backfill needed" shape as v32's identical column on
        // `outboxMessage`.
        migrator.registerMigration("v33") { db in
            try db.alter(table: "draftMessage") { t in
                t.add(column: "htmlBody", .text)
            }
        }

        // v34 (Task #162, 実機フィードバック「署名が本文に混ざって編集しづらい」):
        // `DraftMessageRecord.signatureId`'s doc comment has the full
        // picture — `NULL` for every existing row (no backfill), non-`NULL`
        // only for a row `ComposerView.saveDraft()` writes from here on.
        migrator.registerMigration("v34") { db in
            try db.alter(table: "draftMessage") { t in
                t.add(column: "signatureId", .integer)
            }
        }

        // v35 (Task #168, 実機フィードバック「一覧のスレッド通数バッジが
        // 実際の通数と食い違う」（Gmail、Oktaの通知メール）): a54f585 made
        // `thread.messageCount`/`unreadCount` dedup-aware (Gmail の INBOX と
        // All Mail の二重行を1通として数える) for every future write to
        // those columns via `ThreadAssigner.recomputeAggregates(threadId:
        // db:)`/`.apply(_:accountId:db:)`, but never backfilled threads
        // whose stored value was already written with the old (dedup前の)
        // count before that fix shipped — a thread stays wrong until its
        // membership changes again and triggers a fresh write. This
        // migration recomputes every existing thread's aggregates once,
        // via `ThreadAssigner.recomputeAllAggregates(db:)` (a single `UPDATE
        // thread SET ...` statement reusing the exact same dedup SQL
        // `apply`'s per-batch path already uses — one definition, not three).
        // Raw SQL inside that helper, not `ThreadRecord`/`MessageRecord`
        // fetch-then-update — deliberately, for the same "frozen schema vs.
        // live Codable struct shape" reason v21's migration documents:
        // every column this UPDATE touches (`thread.messageCount`,
        // `message.gmailMessageId`, `mailbox.role`, etc.) already existed
        // well before v34, so referencing them by raw column name here is
        // safe regardless of columns added by migrations after this one.
        migrator.registerMigration("v35") { db in
            try ThreadAssigner.recomputeAllAggregates(db: db)
        }

        // v36 (実機フィードバック: HTML本文の quoted-printable ソフト改行
        // 消化漏れ — `MailCoreIMAPSession+Mapping.swift`の`html(from:)`修正
        // 後も、同じメールでまだ翻訳が失敗した): 修正は**新規フェッチにしか
        // 効かない** — 既存の`messageBody`行には修正前の壊れたhtmlがその
        // まま残っている (Task #134と全く同じ制約)。全件に`DEFAULT 0`で
        // `renderVersion`列を足すだけで済ませる — SQLite側が既存行全てへ
        // 自動適用するので、手動のfetch-then-updateバックフィルは不要
        // (`MessageBodyRecord.currentRenderVersion`のdoc comment参照)。
        // `0`は`MessageBodyRecord.currentRenderVersion`(1)より必ず古い値
        // になるので、既存行は次にそのメッセージを開いた瞬間 `MessageView
        // .load()`のキャッシュ利用ガードにより「本文キャッシュ未取得」と
        // 同等に扱われ、遅延的に (そのメッセージだけ) 再フェッチされる —
        // 起動時に全件を一括再取得することはしない (数千件規模になりうる
        // ため)。
        migrator.registerMigration("v36") { db in
            try db.alter(table: "messageBody") { t in
                t.add(column: "renderVersion", .integer).notNull().defaults(to: 0)
            }
        }

        // v37 (Task #186, iCloud で設定全般を同期): `signatureTemplate`/
        // `mailTemplate` gain a `syncId` — a `UUID` string generated once
        // per row, immutable for its lifetime — as the cross-device-stable
        // identity `TemplateCloudSyncEngine` (`AccountCloudSync`) reconciles
        // on. The existing `id` (`AUTOINCREMENT`, referenced by
        // `account.defaultSignatureId`/`Composer`'s in-memory selection/
        // `LastSignatureSettingsStore`'s per-account `UserDefaults` key)
        // stays exactly what the v24 migration's comment above already
        // explains it must stay — a device-local row number with no
        // cross-device meaning — so it is deliberately *not* part of the
        // synced payload; only `syncId` ever leaves this device. This
        // finally implements the "Syncing the signatures themselves is
        // future work this batch doesn't attempt" deferral that v24's
        // comment flagged.
        //
        // Two-step `ADD COLUMN` (nullable first, backfill, no `NOT NULL`
        // constraint added after) rather than a single `.notNull()` column
        // definition: SQLite's `ADD COLUMN ... NOT NULL` requires a single
        // *constant* default for every existing row, but each row needs its
        // *own* fresh UUID — the same reason `v18`'s `toText`/`ccText`
        // backfill above is a nullable column plus a Swift-side per-row
        // loop, not a one-shot SQL default. A `UNIQUE` index (not a `NOT
        // NULL` constraint) is what actually keeps this column populated
        // going forward: `SignatureTemplateRecord.init`/`MailTemplateRecord
        // .init` both default `syncId` to a fresh `UUID().uuidString`, so
        // every row inserted after this migration always has one; the
        // column stays nullable at the SQLite level purely so this
        // migration doesn't need a same-transaction "add NOT NULL" step
        // GRDB's `alter(table:)` doesn't expose directly.
        migrator.registerMigration("v37") { db in
            try db.alter(table: "signatureTemplate") { t in
                t.add(column: "syncId", .text)
            }
            try db.alter(table: "mailTemplate") { t in
                t.add(column: "syncId", .text)
            }
            // Raw SQL, not `SignatureTemplateRecord`/`MailTemplateRecord`'s
            // `Codable` fetch — those Swift structs declare `syncId` as a
            // non-optional `String` (matching every row *after* this
            // migration finishes), but right after the `ADD COLUMN` above
            // every existing row's `syncId` is still SQL `NULL`; decoding
            // through the Codable record at that intermediate point would
            // throw before this loop ever gets to backfill it.
            for id in try Int64.fetchAll(db, sql: "SELECT id FROM signatureTemplate") {
                try db.execute(sql: "UPDATE signatureTemplate SET syncId = ? WHERE id = ?", arguments: [UUID().uuidString, id])
            }
            for id in try Int64.fetchAll(db, sql: "SELECT id FROM mailTemplate") {
                try db.execute(sql: "UPDATE mailTemplate SET syncId = ? WHERE id = ?", arguments: [UUID().uuidString, id])
            }
            // A `UNIQUE` index, not `NOT NULL` — see this migration's doc
            // comment above for why the column itself stays nullable at the
            // SQLite level. SQLite treats multiple `NULL`s in a `UNIQUE`
            // index as non-conflicting, so this is safe even though the
            // column has no `NOT NULL` constraint of its own.
            try db.create(index: "signatureTemplate_on_syncId", on: "signatureTemplate", columns: ["syncId"], unique: true)
            try db.create(index: "mailTemplate_on_syncId", on: "mailTemplate", columns: ["syncId"], unique: true)
        }

        // v38 (Task #193, 実機バグ「10年以上前に送った送信済みメールが、
        // 6時間前くらいの日付で受信箱に表示される」): a MailCore2 bug this
        // app used to inherit verbatim — `EnvelopeDateSentinel`'s doc
        // comment has the full root cause — could stamp `message.date`
        // with whatever moment a message was *fetched* rather than its real
        // `Date:` header, for any message whose header was missing or
        // malformed one. `MailCoreIMAPSession+Mapping.envelope(from:
        // fetchedAt:)`'s fix stops this for every future fetch, but does
        // nothing for a `date` already written that way, or for a thread a
        // so-corrupted row already merged into via `Threader`'s subject-
        // fallback pass (a years-old message that *looked* freshly sent
        // easily lands inside that pass's 7-day window against whatever
        // recent thread shares its subject and a participant). This
        // migration runs `ThreadAssigner.repairSentinelDates(db:)` once for
        // every existing install — see that function's doc comment for how
        // it identifies an already-corrupted row (there's no stored
        // "fetched at" moment to check against, only `updatedAt`) and how
        // it re-threads it.
        migrator.registerMigration("v38") { db in
            try ThreadAssigner.repairSentinelDates(db: db)
        }

        return migrator
    }
}
