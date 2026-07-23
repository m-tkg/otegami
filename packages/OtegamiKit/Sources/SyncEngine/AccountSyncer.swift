import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore

/// Drives sync for a single account: initial sync today (M1); differential
/// sync, flag sync, and `opQueue` replay land in M3. One instance owns no
/// long-lived IMAP connection of its own — each sync pass opens, uses, and
/// closes its own session — so it's safe to keep around across repeated
/// manual/pull-to-refresh syncs without worrying about a stale connection.
public actor AccountSyncer {
    /// How many of a mailbox's most recent messages the initial sync
    /// fetches (plan: "直近500件"). A ceiling, not a guarantee: mailboxes
    /// with fewer messages, or gaps from expunged UIDs, yield fewer.
    public static let initialSyncWindow: UInt32 = 500

    /// How many UIDs `fetchEnvelopes` requests per underlying FETCH
    /// command (plan: "100 件ずつバッチで").
    public static let fetchBatchSize = 100

    /// Progress reported during ``performInitialSync(auth:onProgress:)``,
    /// e.g. to drive a progress indicator in `AccountSetupView`.
    public struct Progress: Sendable, Equatable {
        public var mailboxesDiscovered: Int = 0
        public var selectedMailboxPath: String?
        public var envelopesFetched: Int = 0
        /// How many of the recent-message body prefetch (M2) succeeded.
        public var bodiesFetched: Int = 0
    }

    private let account: AccountRecord
    private let database: AppDatabase
    private let sessionFactory: @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    private let bodyFetcher: BodyFetcher

    public init(
        account: AccountRecord,
        database: AppDatabase,
        sessionFactory: @escaping @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    ) {
        self.account = account
        self.database = database
        self.sessionFactory = sessionFactory
        self.bodyFetcher = BodyFetcher(database: database)
    }

    /// Connects, lists mailboxes (upserting all of them), then selects
    /// INBOX and fetches its most recent ``initialSyncWindow`` envelopes in
    /// ``fetchBatchSize``-sized batches, upserting `message`/
    /// `messageReference` rows as it goes. Idempotent: safe to call again
    /// (e.g. from a manual refresh) — re-fetched envelopes overwrite the
    /// existing row for their `(mailboxId, uid)` rather than duplicating.
    ///
    /// Only INBOX is synced in M1; other mailboxes are upserted (so the
    /// sidebar can list them) but not fetched. Full multi-mailbox sync
    /// lands with differential sync in M3.
    @discardableResult
    public func performInitialSync(
        auth: MailAuth,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Progress {
        var progress = Progress()

        let session = sessionFactory(account.imapConfig)
        try await session.connect(auth: auth)
        defer {
            let session = session
            Task { await session.disconnect() }
        }

        let mailboxInfos = try await session.listMailboxes()
        progress.mailboxesDiscovered = mailboxInfos.count
        onProgress?(progress)

        let mailboxRecordsByPath = try await database.dbWriter.write { [account] db -> [String: MailboxRecord] in
            var records: [String: MailboxRecord] = [:]
            for info in mailboxInfos {
                var record = MailboxRecord(
                    accountId: account.id,
                    path: info.path,
                    displayPath: info.displayPath,
                    delimiter: info.delimiter,
                    role: MailboxRoleRecord(info.role),
                    attributesRaw: info.attributes.rawValue
                )
                record = try record.upsertAndFetch(db, onConflict: ["accountId", "path"])
                records[info.path] = record
            }
            return records
        }

        guard let inboxInfo = Self.inbox(among: mailboxInfos),
              let inboxRecord = mailboxRecordsByPath[inboxInfo.path],
              let inboxId = inboxRecord.id
        else {
            return progress
        }

        progress.selectedMailboxPath = inboxInfo.path
        onProgress?(progress)

        let status = try await session.select(inboxInfo.path)

        if status.messageCount > 0, status.uidNext > 1 {
            let lowerBound = Self.initialSyncLowerBound(uidNext: status.uidNext, window: Self.initialSyncWindow)
            let range = UIDRange(lowerBound: lowerBound, upperBound: nil)
            let envelopes = try await session.fetchEnvelopes(
                mailboxPath: inboxInfo.path,
                uids: range,
                batchSize: Self.fetchBatchSize
            )

            try await database.dbWriter.write { db in
                for envelope in envelopes {
                    try Self.upsert(envelope: envelope, mailboxId: inboxId, db: db)
                }
            }

            progress.envelopesFetched = envelopes.count
            onProgress?(progress)
        }

        // `inboxRecord` is captured as a `let` snapshot rather than
        // mutated directly inside the closure: `DatabaseWriter.write`'s
        // closure is `@Sendable`, and mutating a captured `var` across a
        // Sendable closure boundary is rejected under Swift 6 strict
        // concurrency even though `AccountSyncer` itself is actor-isolated.
        let syncedInboxRecord = inboxRecord
        try await database.dbWriter.write { db in
            var record = syncedInboxRecord
            record.uidValidity = Int64(status.uidValidity)
            record.uidNext = Int64(status.uidNext)
            record.highestModSeq = Int64(status.highestModSeq)
            record.messageCount = status.messageCount
            record.lastSyncedAt = Date()
            try record.update(db)
        }

        // Prefetch bodies for the most recent messages (plan: "初期同期後に
        // 直近50件を優先度順に先読み") while `session` is still open — this
        // reuses the same connection rather than paying a fresh IMAP
        // handshake per message. Best-effort: `prefetchRecent` already
        // swallows individual message failures, and initial sync itself
        // shouldn't fail just because prefetch couldn't run at all (e.g. a
        // mid-sync disconnect) — the message list still renders fine with
        // bodies fetched lazily on open instead.
        if let inboxId = inboxRecord.id {
            progress.bodiesFetched = (try? await bodyFetcher.prefetchRecent(
                mailboxId: inboxId,
                mailboxPath: inboxInfo.path,
                session: session
            )) ?? 0
            onProgress?(progress)
        }

        return progress
    }

    /// The lower UID bound that yields (at most) `window` messages,
    /// assuming a dense (gap-free) UID space: everything from
    /// `uidNext - window` onward. Servers with expunged messages (gaps)
    /// will simply return fewer than `window` envelopes for this range,
    /// which callers treat as fine.
    static func initialSyncLowerBound(uidNext: UInt32, window: UInt32) -> UInt32 {
        let highestPossibleUID = uidNext - 1
        return highestPossibleUID > window ? highestPossibleUID - window + 1 : 1
    }

    private static func inbox(among mailboxes: [MailboxInfo]) -> MailboxInfo? {
        mailboxes.first { $0.role == .inbox }
            ?? mailboxes.first { $0.path.caseInsensitiveCompare("INBOX") == .orderedSame }
    }

    /// Upserts one envelope's `message` row (keyed by `(mailboxId, uid)`)
    /// and replaces its `messageReference` rows wholesale (cheaper than
    /// diffing, and references rarely change for an already-seen message).
    static func upsert(envelope: FetchedEnvelope, mailboxId: Int64, db: Database) throws {
        var record = MessageRecord(
            mailboxId: mailboxId,
            uid: Int64(envelope.uid),
            messageId: envelope.messageId,
            inReplyTo: envelope.inReplyTo,
            subject: envelope.subject,
            normalizedSubject: envelope.subject.map(SubjectNormalizer.normalize),
            fromAddresses: envelope.from,
            toAddresses: envelope.to,
            ccAddresses: envelope.cc,
            bccAddresses: envelope.bcc,
            replyToAddresses: envelope.replyTo,
            date: envelope.date,
            internalDate: envelope.internalDate,
            flagsRaw: envelope.flags.rawValue,
            size: envelope.size,
            gmailThreadId: envelope.gmailThreadId.map { Int64(bitPattern: $0) },
            gmailMessageId: envelope.gmailMessageId.map { Int64(bitPattern: $0) },
            hasAttachments: envelope.hasAttachments,
            updatedAt: Date()
        )
        // `createdAt` is excluded from the update side of the upsert so a
        // resync doesn't overwrite the original insert timestamp.
        record = try record.upsertAndFetch(db, onConflict: ["mailboxId", "uid"]) { _ in
            [Column("createdAt").noOverwrite]
        }
        guard let messageId = record.id else { return }

        try MessageReferenceRecord
            .filter(Column("messageId") == messageId)
            .deleteAll(db)
        for (index, reference) in envelope.references.enumerated() {
            var referenceRecord = MessageReferenceRecord(messageId: messageId, referenceValue: reference, position: index)
            try referenceRecord.insert(db)
        }
    }
}
