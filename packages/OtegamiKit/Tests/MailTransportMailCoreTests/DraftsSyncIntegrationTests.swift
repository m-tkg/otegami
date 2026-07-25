import Foundation
import GRDB
import Testing
@testable import MailTransportMailCore
import MailTransport
import OtegamiCore
import OtegamiStore
import SyncEngine

/// Drafts IMAP sync, end to end against the real dev mailstack (Dovecot +
/// Mailpit) — the scenarios `docs/verify.md`'s "統合 (dev/mailstack の実
/// Dovecot)" section describes, on top of the `FakeIMAPSession`-driven
/// coverage in `SyncEngineTests/OpQueueProcessorTests.swift` (which proves
/// the same logic in isolation but can't confirm the real `APPEND`/`STORE`/
/// `EXPUNGE` wire behavior, or that a message injected by a genuinely
/// different client — `doveadm`, standing in for one — is actually picked
/// up by `AccountSyncer`).
///
/// Opt-in like the rest of this target: skipped unless
/// `OTEGAMI_TEST_IMAP_HOST` is set. Run with:
///
/// ```sh
/// make mailstack-up
/// OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter DraftsSyncIntegrationTests
/// make mailstack-down
/// ```
@Suite(
    "Drafts IMAP sync against dev mailstack",
    .enabled(if: TestIMAPEnvironment.primary != nil, "set OTEGAMI_TEST_IMAP_HOST to run"),
    .serialized
)
struct DraftsSyncIntegrationTests {
    private func makeAccount(env: TestIMAPEnvironment, withSMTP: Bool = false) -> AccountRecord {
        AccountRecord(
            displayName: "Integration",
            email: env.username,
            authType: .password,
            imapHost: env.host,
            imapPort: env.port,
            imapSecurity: ConnectionSecurityRecord(env.imapConfig.security),
            imapAllowsInsecureTLS: env.imapConfig.allowsInsecureTLS,
            imapUsername: env.username,
            smtpHost: withSMTP ? env.host : nil,
            smtpPort: withSMTP ? 1025 : nil,
            smtpSecurity: withSMTP ? .plain : nil,
            smtpUsername: withSMTP ? "" : nil
        )
    }

    /// Discovers/upserts the account's mailboxes (including the real,
    /// already-`SPECIAL-USE`-advertised Drafts mailbox this dev mailstack's
    /// Dovecot auto-creates) — the same step `AccountSetupView.saveAccount`
    /// always runs before an app user could ever reach a "save draft"/
    /// "delete draft"/"send" action. `OpQueueProcessor.resolveOrCreateDraftsMailbox`'s
    /// `CREATE`-self-heal path only activates when *no local* `mailbox` row
    /// is known yet, which would otherwise collide with this server's
    /// already-existing `Drafts` mailbox (`CREATE` on an existing name
    /// fails) — an edge case that doesn't arise in real usage precisely
    /// because this sync step always runs first, so every test in this
    /// suite calls this rather than enqueueing straight against a
    /// zero-mailboxes-known account.
    private func syncMailboxes(account: AccountRecord, database: AppDatabase, env: TestIMAPEnvironment) async throws {
        let syncer = AccountSyncer(account: account, database: database) { config in MailCoreIMAPSession(config: config) }
        _ = try await syncer.performInitialSync(auth: env.auth)
    }

    private static func sampleMessage(subject: String, marker: String) -> String {
        "From: Other Client <other@otegami.test>\r\n" +
            "To: \(marker)@otegami.test\r\n" +
            "Subject: \(subject)\r\n" +
            "Message-Id: <\(marker)@otegami.test>\r\n" +
            "Date: Mon, 1 Jan 2024 00:00:00 +0900\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "\r\n" +
            "Written by another IMAP client directly into Drafts.\r\n"
    }

    @Test("saving a local draft APPENDs it to the real Drafts mailbox with the \\Draft flag")
    func saveDraftAppendsToRealDraftsMailbox() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let user = env.username
        try DoveadmHelper.expungeAll(user: user, mailboxPath: "Drafts")
        defer { try? DoveadmHelper.expungeAll(user: user, mailboxPath: "Drafts") }

        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(env: env)
        try await database.dbWriter.write { db in try account.insert(db) }
        try await syncMailboxes(account: account, database: database, env: env)

        let uniqueMarker = UUID().uuidString.prefix(8)
        let subject = "otegami Drafts統合テスト \(uniqueMarker)"
        let draft = try await database.dbWriter.write { db -> DraftMessageRecord in
            var draft = DraftMessageRecord(
                accountId: account.id,
                toAddresses: [EmailAddress(address: "recipient@otegami.test")],
                subject: subject,
                plainTextBody: "統合テストの下書き本文です。"
            )
            try draft.insert(db)
            try OpQueue.enqueueSaveDraft(accountId: account.id, draftMessageId: draft.id!, db: db)
            return draft
        }

        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in MailCoreIMAPSession(config: config) },
            messageBuilder: { MailCoreMessageBuilder.build($0) }
        )
        let result = try await processor.replay(account: account, auth: env.auth)
        #expect(result.succeeded == 1)

        #expect(!DoveadmHelper.fetchFlagsBySubject(user: user, mailboxPath: "Drafts", subject: subject).isEmpty)
        #expect(DoveadmHelper.fetchFlagsBySubject(user: user, mailboxPath: "Drafts", subject: subject).contains("\\Draft"))

        let updated = try await database.dbWriter.read { db in try DraftMessageRecord.fetchOne(db, key: draft.id!) }
        #expect(updated?.serverMailboxId != nil)
        #expect(updated?.serverUid != nil, "Dovecot supports UIDPLUS, so APPEND should return the new UID")
    }

    @Test("editing and re-saving a draft replaces the server copy — exactly one message survives in Drafts")
    func editingADraftReplacesRatherThanDuplicates() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let user = env.username
        try DoveadmHelper.expungeAll(user: user, mailboxPath: "Drafts")
        defer { try? DoveadmHelper.expungeAll(user: user, mailboxPath: "Drafts") }

        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(env: env)
        try await database.dbWriter.write { db in try account.insert(db) }
        try await syncMailboxes(account: account, database: database, env: env)

        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in MailCoreIMAPSession(config: config) },
            messageBuilder: { MailCoreMessageBuilder.build($0) }
        )

        // First save.
        let uniqueMarker = UUID().uuidString.prefix(8)
        let draftId = try await database.dbWriter.write { db -> Int64 in
            var draft = DraftMessageRecord(
                accountId: account.id,
                toAddresses: [EmailAddress(address: "recipient@otegami.test")],
                subject: "版1 \(uniqueMarker)",
                plainTextBody: "最初の内容。"
            )
            try draft.insert(db)
            try OpQueue.enqueueSaveDraft(accountId: account.id, draftMessageId: draft.id!, db: db)
            return draft.id!
        }
        var result = try await processor.replay(account: account, auth: env.auth)
        #expect(result.succeeded == 1)
        #expect(DoveadmHelper.messageCount(user: user, mailboxPath: "Drafts") == 1)

        // "Resume and edit": mutate the same row's text and its `serverUid`/
        // `serverMailboxId`/`serverUidValidity` stay put (this mirrors what
        // `ComposerView.loadDraft`+`saveDraft` do across two Composer
        // sessions, without needing the full app UI layer for this test —
        // the row is the single source of truth `.saveDraft` replay reads
        // from either way).
        try await database.dbWriter.write { db in
            guard var draft = try DraftMessageRecord.fetchOne(db, key: draftId) else { return }
            draft.subject = "版2 \(uniqueMarker)"
            draft.plainTextBody = "編集後の内容。"
            draft.updatedAt = Date()
            try draft.update(db)
            try OpQueue.enqueueSaveDraft(accountId: account.id, draftMessageId: draftId, db: db)
        }
        result = try await processor.replay(account: account, auth: env.auth)
        #expect(result.succeeded == 1)

        // Replaced, not duplicated.
        #expect(DoveadmHelper.messageCount(user: user, mailboxPath: "Drafts") == 1)
        #expect(!DoveadmHelper.fetchFlagsBySubject(user: user, mailboxPath: "Drafts", subject: "版2 \(uniqueMarker)").isEmpty)
        #expect(DoveadmHelper.fetchFlagsBySubject(user: user, mailboxPath: "Drafts", subject: "版1 \(uniqueMarker)").isEmpty)
    }

    @Test("sending a message resumed from a draft deletes its Drafts copy once the send succeeds")
    func sendingFromADraftDeletesTheDraftsCopy() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let user = env.username
        try DoveadmHelper.expungeAll(user: user, mailboxPath: "Drafts")
        defer { try? DoveadmHelper.expungeAll(user: user, mailboxPath: "Drafts") }

        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(env: env, withSMTP: true)
        try await database.dbWriter.write { db in try account.insert(db) }
        try await syncMailboxes(account: account, database: database, env: env)

        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in MailCoreIMAPSession(config: config) },
            smtpSessionFactory: { config in MailCoreSMTPSession(config: config) },
            messageBuilder: { MailCoreMessageBuilder.build($0) }
        )

        // Save a draft first, so it has a real server ref to clean up.
        let uniqueMarker = UUID().uuidString.prefix(8)
        let subject = "送信予定の下書き \(uniqueMarker)"
        let draft = try await database.dbWriter.write { db -> DraftMessageRecord in
            var draft = DraftMessageRecord(
                accountId: account.id, toAddresses: [EmailAddress(address: "recipient@otegami.test")],
                subject: subject, plainTextBody: "送信されるはずの内容。"
            )
            try draft.insert(db)
            try OpQueue.enqueueSaveDraft(accountId: account.id, draftMessageId: draft.id!, db: db)
            return draft
        }
        var result = try await processor.replay(account: account, auth: env.auth)
        #expect(result.succeeded == 1)
        #expect(DoveadmHelper.messageCount(user: user, mailboxPath: "Drafts") == 1)

        let savedDraft = try #require(try await database.dbWriter.read { db in try DraftMessageRecord.fetchOne(db, key: draft.id!) })
        let draftMailboxId = try #require(savedDraft.serverMailboxId)
        let draftUid = try #require(savedDraft.serverUid)
        let draftUidValidity = try #require(savedDraft.serverUidValidity)

        // "Resume into Composer and send": an outbox row carrying the
        // draft's server ref, the same fields `ComposerView.send()` copies
        // from its `draftServerMailboxId`/etc. `@State`.
        try await database.dbWriter.write { db in
            var outbox = OutboxMessageRecord(
                accountId: account.id, toAddresses: [EmailAddress(address: "recipient@otegami.test")],
                subject: subject, plainTextBody: "送信されるはずの内容。",
                draftServerMailboxId: draftMailboxId, draftServerUid: draftUid, draftServerUidValidity: draftUidValidity
            )
            try outbox.insert(db)
            try OpQueue.enqueueSend(accountId: account.id, outboxMessageId: outbox.id!, db: db)
        }
        result = try await processor.replay(account: account, auth: env.auth)
        #expect(result.succeeded == 1)

        #expect(DoveadmHelper.messageCount(user: user, mailboxPath: "Drafts") == 0, "the Drafts copy must not survive a successful send")

        let found = try await MailpitClient.pollForMessage(withSubjectContaining: String(uniqueMarker), timeout: 15)
        #expect(found?.subject == subject)
    }

    @Test("deleting a draft (deleteDraft op) removes it from the real Drafts mailbox")
    func deletingADraftRemovesItFromDrafts() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let user = env.username
        try DoveadmHelper.expungeAll(user: user, mailboxPath: "Drafts")
        defer { try? DoveadmHelper.expungeAll(user: user, mailboxPath: "Drafts") }

        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(env: env)
        try await database.dbWriter.write { db in try account.insert(db) }
        try await syncMailboxes(account: account, database: database, env: env)

        let processor = OpQueueProcessor(
            database: database,
            sessionFactory: { config in MailCoreIMAPSession(config: config) },
            messageBuilder: { MailCoreMessageBuilder.build($0) }
        )

        let draft = try await database.dbWriter.write { db -> DraftMessageRecord in
            var draft = DraftMessageRecord(
                accountId: account.id, toAddresses: [EmailAddress(address: "recipient@otegami.test")],
                subject: "削除される下書き", plainTextBody: "内容。"
            )
            try draft.insert(db)
            try OpQueue.enqueueSaveDraft(accountId: account.id, draftMessageId: draft.id!, db: db)
            return draft
        }
        _ = try await processor.replay(account: account, auth: env.auth)
        #expect(DoveadmHelper.messageCount(user: user, mailboxPath: "Drafts") == 1)

        let saved = try #require(try await database.dbWriter.read { db in try DraftMessageRecord.fetchOne(db, key: draft.id!) })
        try await database.dbWriter.write { db in
            try OpQueue.enqueueDeleteDraft(
                accountId: account.id, mailboxId: saved.serverMailboxId!, uidValidity: saved.serverUidValidity!,
                uid: UInt32(truncatingIfNeeded: saved.serverUid!), db: db
            )
        }
        let result = try await processor.replay(account: account, auth: env.auth)
        #expect(result.succeeded == 1)
        #expect(DoveadmHelper.messageCount(user: user, mailboxPath: "Drafts") == 0)
    }

    @Test("a draft written directly to Drafts by another client is picked up by AccountSyncer and surfaced by DraftQuery")
    func externallyWrittenDraftIsSyncedAndSurfaced() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let user = env.username
        try DoveadmHelper.expungeAll(user: user, mailboxPath: "Drafts")
        defer { try? DoveadmHelper.expungeAll(user: user, mailboxPath: "Drafts") }

        let uniqueMarker = String(UUID().uuidString.prefix(8))
        let subject = "他クライアントが書いた下書き \(uniqueMarker)"
        try DoveadmHelper.save(user: user, mailboxPath: "Drafts", content: Self.sampleMessage(subject: subject, marker: uniqueMarker))

        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(env: env)
        try await database.dbWriter.write { db in try account.insert(db) }

        let syncer = AccountSyncer(account: account, database: database) { config in MailCoreIMAPSession(config: config) }
        _ = try await syncer.performInitialSync(auth: env.auth)

        let items = try await database.dbWriter.read { db in try DraftQuery.unifiedRequest(accountIds: [account.id], db: db) }
        #expect(items.contains { $0.subject == subject })
        guard case .server = items.first(where: { $0.subject == subject }) else {
            Issue.record("Expected the externally-written draft to surface as a .server row, not .local")
            return
        }
    }
}
