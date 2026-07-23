import Foundation
import GRDB

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
    /// `<Application Support>/otegami/otegami.sqlite`. Creates the
    /// directory if needed.
    public static func makeShared() throws -> AppDatabase {
        let directory = try applicationSupportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("otegami.sqlite")
        let dbPool = try DatabasePool(path: url.path, configuration: makeConfiguration())
        return try AppDatabase(dbPool)
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

        return migrator
    }
}
