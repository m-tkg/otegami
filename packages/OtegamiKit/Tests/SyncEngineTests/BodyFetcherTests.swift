import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

@Suite("BodyFetcher")
struct BodyFetcherTests {
    /// Inserts an account/mailbox/message row (as if `AccountSyncer` had
    /// already run envelope sync) and returns the fully-identified
    /// `MessageRecord`, ready for `BodyFetcher.fetchBody` to act on.
    private func makeSyncedMessage(
        database: AppDatabase,
        uid: Int64 = 1,
        subject: String = "テスト"
    ) async throws -> MessageRecord {
        let account = AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
        try await database.dbWriter.write { db in try account.insert(db) }

        return try await database.dbWriter.write { db in
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var message = MessageRecord(
                mailboxId: mailbox.id!,
                uid: uid,
                subject: subject,
                internalDate: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try message.insert(db)
            return message
        }
    }

    @Test("plain-only body: stored verbatim, snippet derived from it")
    func plainOnlyBody() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database)
        let content = MessageBodyContent(plainText: "test1 さん\n\nようこそ otegami へ。\n\nよろしくお願いします。")
        let script = FakeIMAPSession.Script(bodiesByPath: ["INBOX": [UInt32(message.uid): content]])
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        let fetcher = BodyFetcher(database: database)
        try await fetcher.fetchBody(message: message, mailboxPath: "INBOX", session: session)

        let (body, updated) = try await database.dbWriter.read { db in
            (
                try MessageBodyRecord.fetchOne(db, key: message.id),
                try MessageRecord.fetchOne(db, key: message.id)
            )
        }
        #expect(body?.plainText == content.plainText)
        #expect(body?.html == nil)
        #expect(updated?.bodyState == .fetched)
        #expect(updated?.snippet == "test1 さん ようこそ otegami へ。 よろしくお願いします。")
    }

    #if canImport(NaturalLanguage)
    @Test("fetching an English body sets message.detectedLanguage to \"en\"")
    func detectsEnglishLanguage() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database, subject: "Welcome")
        let content = MessageBodyContent(plainText: "Hi team, the quarterly report is attached. Please review it by Friday and send me your comments. Thanks!")
        let script = FakeIMAPSession.Script(bodiesByPath: ["INBOX": [UInt32(message.uid): content]])
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        try await BodyFetcher(database: database).fetchBody(message: message, mailboxPath: "INBOX", session: session)

        let updated = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: message.id) }
        #expect(updated?.detectedLanguage == "en")
    }

    @Test("fetching a Japanese body sets message.detectedLanguage to \"ja\"")
    func detectsJapaneseLanguage() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database)
        let content = MessageBodyContent(plainText: "test1 さん\n\nようこそ otegami へ。\n\nよろしくお願いします。")
        let script = FakeIMAPSession.Script(bodiesByPath: ["INBOX": [UInt32(message.uid): content]])
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        try await BodyFetcher(database: database).fetchBody(message: message, mailboxPath: "INBOX", session: session)

        let updated = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: message.id) }
        #expect(updated?.detectedLanguage == "ja")
    }
    #endif

    @Test("HTML-only body: plainText backfilled by extracting text from the HTML")
    func htmlOnlyBody() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database, subject: "HTML専用")
        let html = "<html><body><p>こんにちは、otegami です。</p><p>これはHTML専用の日本語メールです。</p></body></html>"
        let content = MessageBodyContent(html: html)
        let script = FakeIMAPSession.Script(bodiesByPath: ["INBOX": [UInt32(message.uid): content]])
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        let fetcher = BodyFetcher(database: database)
        try await fetcher.fetchBody(message: message, mailboxPath: "INBOX", session: session)

        let body = try await database.dbWriter.read { db in try MessageBodyRecord.fetchOne(db, key: message.id) }
        #expect(body?.html == html)
        #expect(body?.plainText == "こんにちは、otegami です。\nこれはHTML専用の日本語メールです。")

        let updated = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: message.id) }
        #expect(updated?.snippet == "こんにちは、otegami です。 これはHTML専用の日本語メールです。")
    }

    @Test("both plain and HTML present: both stored, plainText not overwritten by HTML extraction")
    func bothPlainAndHTMLBody() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database, subject: "両方")
        let content = MessageBodyContent(
            plainText: "プレーンテキスト版です。",
            html: "<p>HTML版です。</p>"
        )
        let script = FakeIMAPSession.Script(bodiesByPath: ["INBOX": [UInt32(message.uid): content]])
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        try await BodyFetcher(database: database).fetchBody(message: message, mailboxPath: "INBOX", session: session)

        let body = try await database.dbWriter.read { db in try MessageBodyRecord.fetchOne(db, key: message.id) }
        #expect(body?.plainText == "プレーンテキスト版です。")
        #expect(body?.html == "<p>HTML版です。</p>")
    }

    @Test("attachments and inline parts are persisted, inline detected from contentId")
    func attachmentsPersisted() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database, subject: "添付あり")
        let content = MessageBodyContent(
            plainText: "本文です。",
            html: "<p>本文です。</p><img src=\"cid:logo@otegami.test\">",
            parts: [
                MIMEPartInfo(partId: "att-1", mimeType: "application", mimeSubtype: "pdf", filename: "invoice.pdf", isAttachment: true, size: 12345),
                MIMEPartInfo(partId: "att-2", mimeType: "image", mimeSubtype: "png", contentId: "logo@otegami.test", isAttachment: false, size: 2048),
            ]
        )
        let script = FakeIMAPSession.Script(bodiesByPath: ["INBOX": [UInt32(message.uid): content]])
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        try await BodyFetcher(database: database).fetchBody(message: message, mailboxPath: "INBOX", session: session)

        let attachments = try await database.dbWriter.read { db in
            try AttachmentRecord.filter(Column("messageId") == message.id).order(Column("partId")).fetchAll(db)
        }
        #expect(attachments.count == 2)
        #expect(attachments[0].filename == "invoice.pdf")
        #expect(attachments[0].isInline == false)
        #expect(attachments[1].contentId == "logo@otegami.test")
        #expect(attachments[1].isInline == true)

        let updated = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: message.id) }
        #expect(updated?.hasAttachments == true)
    }

    @Test("re-fetching a message replaces its body and attachments rather than duplicating")
    func refetchReplacesBody() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database)
        let fetcher = BodyFetcher(database: database)

        let firstScript = FakeIMAPSession.Script(bodiesByPath: [
            "INBOX": [UInt32(message.uid): MessageBodyContent(
                plainText: "古い本文",
                parts: [MIMEPartInfo(partId: "a", mimeType: "application", mimeSubtype: "pdf", isAttachment: true, size: 1)]
            )],
        ])
        try await fetcher.fetchBody(
            message: message, mailboxPath: "INBOX",
            session: FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: firstScript)
        )

        let secondScript = FakeIMAPSession.Script(bodiesByPath: [
            "INBOX": [UInt32(message.uid): MessageBodyContent(plainText: "新しい本文")],
        ])
        try await fetcher.fetchBody(
            message: message, mailboxPath: "INBOX",
            session: FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: secondScript)
        )

        let body = try await database.dbWriter.read { db in try MessageBodyRecord.fetchOne(db, key: message.id) }
        #expect(body?.plainText == "新しい本文")

        let attachments = try await database.dbWriter.read { db in
            try AttachmentRecord.filter(Column("messageId") == message.id).fetchAll(db)
        }
        #expect(attachments.isEmpty)
    }

    @Test("a fetch failure reverts bodyState to notFetched")
    func fetchFailureRevertsBodyState() async throws {
        let database = try AppDatabase.makeInMemory()
        let message = try await makeSyncedMessage(database: database)
        // No scripted body for this UID: FakeIMAPSession.fetchBody throws.
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: FakeIMAPSession.Script())

        await #expect(throws: (any Error).self) {
            try await BodyFetcher(database: database).fetchBody(message: message, mailboxPath: "INBOX", session: session)
        }

        let updated = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: message.id) }
        #expect(updated?.bodyState == .notFetched)
    }

    @Test("prefetchRecent fetches only the newest not-yet-fetched messages, up to the limit")
    func prefetchRecentRespectsLimitAndOrder() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
        try await database.dbWriter.write { db in try account.insert(db) }

        let mailboxId = try await database.dbWriter.write { db -> Int64 in
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return mailbox.id!
        }

        let bodies: [UInt32: MessageBodyContent] = Dictionary(
            uniqueKeysWithValues: (1...10).map { uid in (UInt32(uid), MessageBodyContent(plainText: "body-\(uid)")) }
        )
        try await database.dbWriter.write { db in
            for uid in 1...10 {
                var message = MessageRecord(
                    mailboxId: mailboxId,
                    uid: Int64(uid),
                    subject: "msg-\(uid)",
                    internalDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid))
                )
                try message.insert(db)
            }
        }

        let script = FakeIMAPSession.Script(bodiesByPath: ["INBOX": bodies])
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        let fetchedCount = try await BodyFetcher(database: database)
            .prefetchRecent(mailboxId: mailboxId, mailboxPath: "INBOX", limit: 3, session: session)
        #expect(fetchedCount == 3)

        let fetchedMessages = try await database.dbWriter.read { db in
            try MessageRecord
                .filter(Column("mailboxId") == mailboxId)
                .filter(Column("bodyState") == MessageBodyState.fetched.rawValue)
                .fetchAll(db)
        }
        // Newest three UIDs (10, 9, 8) — internalDate increases with uid here.
        #expect(Set(fetchedMessages.map(\.uid)) == [10, 9, 8])
    }

    // MARK: - Self-healing a stale (mailboxId, uid) — 実機報告
    // 「一部のメールで本文の取得に失敗し続ける (MailCoreErrorDomain error 19)」

    /// One account with two mailboxes (`INBOX` and Gmail's `All Mail`) —
    /// the shape every self-healing scenario below needs: a message that
    /// went stale in one mailbox, and (for the "found elsewhere" scenario)
    /// its still-valid counterpart in the other.
    private func makeAccountWithTwoMailboxes(database: AppDatabase) async throws -> (accountId: String, inboxId: Int64, allMailId: Int64) {
        let account = AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
        try await database.dbWriter.write { db in try account.insert(db) }
        return try await database.dbWriter.write { db in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            inbox = try inbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var allMail = MailboxRecord(accountId: account.id, path: "[Gmail]/All Mail", displayPath: "[Gmail]/All Mail", role: .all)
            allMail = try allMail.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return (account.id, inbox.id!, allMail.id!)
        }
    }

    /// Inserts a single-message thread in `mailboxId` and returns the
    /// message — mirrors `MessageRemovalTests.insertSingleMessageThread`'s
    /// shape, since it's exactly the case that makes a thread-aggregate
    /// recompute visible (the message being the thread's only one).
    private func insertSingleMessageThread(
        accountId: String, mailboxId: Int64, uid: Int64, messageId: String?, db: Database
    ) throws -> MessageRecord {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var thread = ThreadRecord(accountId: accountId, lastMessageDate: date, messageCount: 1)
        try thread.insert(db)
        var message = MessageRecord(
            mailboxId: mailboxId, uid: uid, messageId: messageId,
            internalDate: date, threadId: thread.id
        )
        try message.insert(db)
        return message
    }

    @Test("stale UID confirmed gone, found by Message-ID in All Mail: repoints and retries, deleting the now-redundant All Mail row")
    func selfHealRepointsToCounterpartAndRetries() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, inboxId, allMailId) = try await makeAccountWithTwoMailboxes(database: database)

        let (inboxMessage, allMailMessage) = try await database.dbWriter.write { db in
            let inboxMessage = try self.insertSingleMessageThread(
                accountId: accountId, mailboxId: inboxId, uid: 5, messageId: "<stale@otegami.test>", db: db
            )
            let allMailMessage = try self.insertSingleMessageThread(
                accountId: accountId, mailboxId: allMailId, uid: 99, messageId: "<stale@otegami.test>", db: db
            )
            return (inboxMessage, allMailMessage)
        }

        // INBOX's copy is gone (archived by another client): `fetchBody`
        // fails with `.serverError` (MailCore error 19's shape), and a
        // follow-up existence check for uid 5 comes back empty. All Mail
        // still has uid 99 for the same Message-ID, with its body ready to
        // serve.
        let script = FakeIMAPSession.Script(
            envelopesByPath: ["INBOX": []],
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: 6, highestModSeq: 0, messageCount: 0),
                "[Gmail]/All Mail": MailboxStatus(uidValidity: 1, uidNext: 100, highestModSeq: 0, messageCount: 1),
            ],
            bodiesByPath: ["[Gmail]/All Mail": [99: MessageBodyContent(plainText: "本文はこちら")]],
            failFetchBody: ["INBOX": [5: .serverError(underlyingDescription: "NO [error 19]")]]
        )
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        // No throw: the caller (on-open fetch / prefetch) sees this as a
        // successful fetch, not an error to surface.
        try await BodyFetcher(database: database).fetchBody(message: inboxMessage, mailboxPath: "INBOX", session: session)

        let (survivingRow, redundantRow, body) = try await database.dbWriter.read { db in
            (
                try MessageRecord.fetchOne(db, key: inboxMessage.id),
                try MessageRecord.fetchOne(db, key: allMailMessage.id),
                try MessageBodyRecord.fetchOne(db, key: inboxMessage.id)
            )
        }
        // The INBOX row's own `id` survived (so anything already holding a
        // reference to it — an open detail view, a thread's `messageCount`
        // — keeps working) but now points at where the message really is.
        #expect(survivingRow?.mailboxId == allMailId)
        #expect(survivingRow?.uid == 99)
        #expect(survivingRow?.bodyState == .fetched)
        #expect(body?.plainText == "本文はこちら")
        // The now-redundant All Mail row was merged away, not left as a
        // second copy of the same physical message.
        #expect(redundantRow == nil)

        // The session re-selected All Mail to retry the fetch, then went
        // back to INBOX — a caller looping over more INBOX messages (e.g.
        // `prefetchRecent`) finds the connection back where it left it.
        let selectedPaths = await session.selectedPaths
        #expect(selectedPaths == ["[Gmail]/All Mail", "INBOX"])
    }

    @Test("stale UID confirmed gone, no counterpart anywhere: the message row and its (now-empty) thread are cleaned up quietly")
    func selfHealCleansUpVanishedMessage() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, inboxId, _) = try await makeAccountWithTwoMailboxes(database: database)

        let message = try await database.dbWriter.write { db in
            try self.insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 7, messageId: "<gone@otegami.test>", db: db)
        }
        let threadId = try #require(message.threadId)

        let script = FakeIMAPSession.Script(
            envelopesByPath: ["INBOX": []],
            failFetchBody: ["INBOX": [7: .serverError(underlyingDescription: "NO [error 19]")]]
        )
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        // No throw: a message that's genuinely gone server-side is resolved
        // by quietly reconciling the local database, not by surfacing an
        // error the user can never fix by retrying.
        try await BodyFetcher(database: database).fetchBody(message: message, mailboxPath: "INBOX", session: session)

        let (row, thread) = try await database.dbWriter.read { db in
            (try MessageRecord.fetchOne(db, key: message.id), try ThreadRecord.fetchOne(db, key: threadId))
        }
        #expect(row == nil)
        // Its only message is gone, so — same contract as
        // `ThreadAssigner.recomputeAggregates`'s doc comment, and
        // `MessageRemoval`'s swipe-delete path — the thread itself goes too.
        #expect(thread == nil)
    }

    @Test("the existence check itself failing (disconnect) never deletes anything — the original error is surfaced unchanged")
    func selfHealNeverDeletesWhenExistenceCheckFails() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, inboxId, _) = try await makeAccountWithTwoMailboxes(database: database)

        let message = try await database.dbWriter.write { db in
            try self.insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 9, messageId: "<maybe@otegami.test>", db: db)
        }

        // The FETCH itself fails with a serverError shape, *and* the
        // follow-up existence check (`fetchEnvelopes`) can't complete
        // either — e.g. the connection dropped in between. This must never
        // be read as "confirmed gone" — the docs/qa-findings.md incident
        // this safety condition guards against is an empty refetch once
        // wiping out a whole mailbox.
        let script = FakeIMAPSession.Script(
            failFetchBody: ["INBOX": [9: .serverError(underlyingDescription: "NO [error 19]")]],
            failFetchEnvelopes: .connectionFailed(underlyingDescription: "disconnected")
        )
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        await #expect(throws: MailTransportError.self) {
            try await BodyFetcher(database: database).fetchBody(message: message, mailboxPath: "INBOX", session: session)
        }

        // Untouched: same mailbox/uid, bodyState reverted exactly like any
        // other ordinary fetch failure.
        let row = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: message.id) }
        #expect(row?.mailboxId == inboxId)
        #expect(row?.uid == 9)
        #expect(row?.bodyState == .notFetched)
    }

    @Test("self-healing only ever re-verifies staleness once per message, per BodyFetcher instance")
    func selfHealOnlyVerifiesOncePerMessage() async throws {
        let database = try AppDatabase.makeInMemory()
        let (accountId, inboxId, _) = try await makeAccountWithTwoMailboxes(database: database)

        // The existence check comes back *non-empty* (uid 11 still there) —
        // so the fetch failure wasn't staleness after all, and self-healing
        // backs off without touching the row. A second, independent
        // `fetchBody` call for the same message must not repeat that
        // existence check either (the "無限にならないよう backoff" requirement) —
        // only the plain fetch itself retries.
        let script = FakeIMAPSession.Script(
            envelopesByPath: ["INBOX": [
                FetchedEnvelope(
                    uid: 11, messageId: "<still-here@otegami.test>", inReplyTo: nil, references: [],
                    subject: nil, from: [], to: [], cc: [], bcc: [], replyTo: [],
                    date: nil, internalDate: Date(timeIntervalSince1970: 1_700_000_000), flags: [], size: 0
                ),
            ]],
            failFetchBody: ["INBOX": [11: .serverError(underlyingDescription: "NO, but the UID is fine")]]
        )
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)
        let fetcher = BodyFetcher(database: database)

        let message = try await database.dbWriter.write { db in
            try self.insertSingleMessageThread(accountId: accountId, mailboxId: inboxId, uid: 11, messageId: "<still-here@otegami.test>", db: db)
        }

        await #expect(throws: MailTransportError.self) {
            try await fetcher.fetchBody(message: message, mailboxPath: "INBOX", session: session)
        }
        var fetchedRangeCount = await session.fetchedRanges.count
        #expect(fetchedRangeCount == 1)

        await #expect(throws: MailTransportError.self) {
            try await fetcher.fetchBody(message: message, mailboxPath: "INBOX", session: session)
        }
        // No second existence check on the same `BodyFetcher` instance.
        fetchedRangeCount = await session.fetchedRanges.count
        #expect(fetchedRangeCount == 1)
    }
}
