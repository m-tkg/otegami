import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// Account edit UI: `SyncCoordinator.syncer(for:)` caches one `AccountSyncer`
/// per account id and, once cached, ignores every later call's `account`
/// argument — including a freshly-edited host/port. `invalidateSyncer(for:)`
/// is the fix (see its doc comment); these tests exercise it directly
/// through `SyncCoordinator`'s public API rather than reaching into
/// `AccountSyncer` internals.
@Suite("SyncCoordinator")
struct SyncCoordinatorTests {
    private func makeAccount(host: String) -> AccountRecord {
        AccountRecord(
            id: "account-1",
            displayName: "Test",
            email: "test1@otegami.test",
            authType: .password,
            imapHost: host,
            imapPort: 1143,
            imapSecurity: .plain,
            imapUsername: "test1@otegami.test"
        )
    }

    private func makeScript() -> FakeIMAPSession.Script {
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        return FakeIMAPSession.Script(
            mailboxes: [inbox],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0)]
        )
    }

    /// Records every host `sessionFactory` was asked to build a session
    /// for, in call order — lets a test assert *which* `AccountRecord` a
    /// sync pass actually connected with, not just that it succeeded. A
    /// plain `NSLock`-protected class (not an actor): `sessionFactory` is a
    /// synchronous `@Sendable` closure, so recording here must be
    /// synchronous too — matching `AccountCloudSyncTests.FakeUbiquitousStore`'s
    /// identical rationale for the same shape.
    private final class HostRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var hosts: [String] { lock.withLock { storage } }
        func record(_ host: String) { lock.withLock { storage.append(host) } }
    }

    @Test("without invalidation, a syncer keeps using the host it was first built with")
    func syncerReusesStaleHostWithoutInvalidation() async throws {
        let database = try AppDatabase.makeInMemory()
        let recorder = HostRecorder()
        let script = makeScript()
        let coordinator = SyncCoordinator(database: database) { config in
            recorder.record(config.host)
            return FakeIMAPSession(config: config, script: script)
        }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let original = makeAccount(host: "host-original")
        try await database.dbWriter.write { db in try original.insert(db) }
        _ = try await coordinator.syncAccount(original, auth: auth)

        // Same account id, edited host — but no `invalidateSyncer` call.
        var edited = original
        edited.imapHost = "host-edited"
        let editedToWrite = edited
        try await database.dbWriter.write { db in try editedToWrite.update(db) }
        _ = try await coordinator.syncAccountIncrementally(edited, auth: auth)

        let hosts = recorder.hosts
        #expect(hosts == ["host-original", "host-original"], "the cached syncer should have ignored the edited account's new host")
    }

    @Test("invalidateSyncer(for:) makes the next sync pass use the freshly-edited account")
    func invalidateSyncerPicksUpEditedHost() async throws {
        let database = try AppDatabase.makeInMemory()
        let recorder = HostRecorder()
        let script = makeScript()
        let coordinator = SyncCoordinator(database: database) { config in
            recorder.record(config.host)
            return FakeIMAPSession(config: config, script: script)
        }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let original = makeAccount(host: "host-original")
        try await database.dbWriter.write { db in try original.insert(db) }
        _ = try await coordinator.syncAccount(original, auth: auth)

        var edited = original
        edited.imapHost = "host-edited"
        let editedToWrite = edited
        try await database.dbWriter.write { db in try editedToWrite.update(db) }

        // The fix under test: drop the cached syncer before the next sync.
        await coordinator.invalidateSyncer(for: edited.id)
        _ = try await coordinator.syncAccountIncrementally(edited, auth: auth)

        let hosts = recorder.hosts
        #expect(hosts == ["host-original", "host-edited"])
    }

    @Test("invalidateSyncer(for:) on an id with no cached syncer is a harmless no-op")
    func invalidateSyncerNoOpForUnknownId() async throws {
        let database = try AppDatabase.makeInMemory()
        let coordinator = SyncCoordinator(database: database) { config in
            FakeIMAPSession(config: config, script: FakeIMAPSession.Script())
        }
        await coordinator.invalidateSyncer(for: "never-synced")
    }

    // MARK: - Task #66: sendCalendarReply

    private func makeAccountWithSMTP() -> AccountRecord {
        AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test",
            smtpHost: "localhost", smtpPort: 1025, smtpSecurity: .plain, smtpUsername: "test1@otegami.test"
        )
    }

    private func makeCalendarReplyDraft() -> ComposeDraft {
        let invite = CalendarInvite(
            uid: "abc123@google.com", sequence: 0,
            organizer: EmailAddress(name: "Organizer", address: "organizer@example.com")
        )
        let selfAddress = EmailAddress(name: "Test One", address: "test1@otegami.test")
        let ics = ICSReplyBuilder.buildReply(for: invite, partStat: .accepted, selfAddress: selfAddress)
        return ComposeDraft(
            from: selfAddress,
            to: [invite.organizer!],
            subject: ICSReplyBuilder.subject(for: invite, partStat: .accepted),
            plainTextBody: ICSReplyBuilder.plainTextBody(for: invite, partStat: .accepted, selfAddress: selfAddress),
            attachments: [
                ComposeAttachment(
                    filename: "invite.ics", mimeType: "text/calendar", data: Data(ics.utf8),
                    contentTypeParameters: ["method": "REPLY"]
                )
            ]
        )
    }

    @Test("sendCalendarReply connects with SMTP auth and sends the reply to the organizer")
    func sendCalendarReplySendsToOrganizer() async throws {
        let database = try AppDatabase.makeInMemory()
        let smtpRecorder = FakeSMTPSession.CallRecorder()
        let coordinator = SyncCoordinator(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script()) },
            smtpSessionFactory: { config in FakeSMTPSession(config: config, script: FakeSMTPSession.Script(), recorder: smtpRecorder) },
            messageBuilder: { draft in
                BuiltMessage(data: Data("fake rfc822 for \(draft.subject)".utf8), messageId: "<fake-\(draft.subject)@otegami.local>")
            }
        )
        let account = makeAccountWithSMTP()
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        try await coordinator.sendCalendarReply(makeCalendarReplyDraft(), account: account, auth: auth)

        let sendCalls = smtpRecorder.sendCalls
        #expect(sendCalls.count == 1)
        #expect(sendCalls.first?.recipients.map(\.address) == ["organizer@example.com"])
        #expect(sendCalls.first?.from.address == "test1@otegami.test")
    }

    @Test("sendCalendarReply throws when the account has no SMTP configuration")
    func sendCalendarReplyThrowsWithoutSMTPConfig() async throws {
        let database = try AppDatabase.makeInMemory()
        let coordinator = SyncCoordinator(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script()) }
        )
        let account = makeAccount(host: "localhost") // no SMTP fields set
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        await #expect(throws: (any Error).self) {
            try await coordinator.sendCalendarReply(makeCalendarReplyDraft(), account: account, auth: auth)
        }
    }

    @Test("sendCalendarReply propagates an SMTP send failure")
    func sendCalendarReplyPropagatesSendFailure() async throws {
        let database = try AppDatabase.makeInMemory()
        let coordinator = SyncCoordinator(
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: FakeIMAPSession.Script()) },
            smtpSessionFactory: { config in
                FakeSMTPSession(config: config, script: FakeSMTPSession.Script(failSend: .serverError(underlyingDescription: "550 rejected")))
            },
            messageBuilder: { draft in
                BuiltMessage(data: Data("fake rfc822 for \(draft.subject)".utf8), messageId: "<fake-\(draft.subject)@otegami.local>")
            }
        )
        let account = makeAccountWithSMTP()
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        await #expect(throws: (any Error).self) {
            try await coordinator.sendCalendarReply(makeCalendarReplyDraft(), account: account, auth: auth)
        }
    }

    // MARK: - Task #152: replayOpQueue triggers a targeted resync

    /// Thread-safe call counter — same `NSLock`-protected `@unchecked
    /// Sendable` shape as `HostRecorder` above, needed because
    /// `sessionFactory` is a synchronous `@Sendable` closure.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        var value: Int { lock.withLock { storage } }
        func increment() { lock.withLock { storage += 1 } }
    }

    @Test("replayOpQueue schedules one batched targeted resync covering every mailbox the applied op touched")
    func replayOpQueueSchedulesTargetedResync() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(host: "localhost")
        try await database.dbWriter.write { db in try account.insert(db) }

        let (inboxId, archiveId) = try await database.dbWriter.write { db -> (Int64, Int64) in
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1)
            try inbox.insert(db)
            var archive = MailboxRecord(accountId: account.id, path: "Archive", displayPath: "Archive", role: .archive, uidValidity: 1)
            try archive.insert(db)
            var message = MessageRecord(mailboxId: inbox.id!, uid: 42, internalDate: Date(), flagsRaw: 0)
            try message.insert(db)
            // Simulate the offline UI flow's enqueue half (the local
            // relocation `MessageRemoval.commit` also does is irrelevant to
            // what's under test here — `OpQueueProcessor.replay`/
            // `SyncCoordinator`'s reaction to it).
            try OpQueue.enqueueArchive(
                accountId: account.id, sourceMailboxId: inbox.id!, uidValidity: inbox.uidValidity, uids: [42], db: db
            )
            return (inbox.id!, archive.id!)
        }

        // `.archive`'s replay touches both the source (INBOX) and the
        // self-healed destination (Archive) — the targeted resync this
        // triggers should cover both, in one connection
        // (`SyncScope.mailboxes(paths:)`), not one connection per mailbox.
        let connectionCount = CallCounter()
        let script = FakeIMAPSession.Script(
            mailboxes: [
                MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: []),
                MailboxInfo(path: "Archive", displayPath: "Archive", role: .archive, attributes: []),
            ],
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: 100, highestModSeq: 0, messageCount: 1),
                "Archive": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0),
            ]
        )
        let coordinator = SyncCoordinator(
            database: database,
            sessionFactory: { config in
                connectionCount.increment()
                return FakeIMAPSession(config: config, script: script)
            },
            // Real production debounce is 2-3s (`TargetedResyncScheduler
            // .defaultDebounceInterval`) — shortened here so this test
            // doesn't have to wait through it in real wall-clock time.
            targetedResyncDebounceInterval: 0.05
        )
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let result = try await coordinator.replayOpQueue(for: account, auth: auth)
        #expect(result.succeeded == 1)
        #expect(result.affectedMailboxIds == Set([inboxId, archiveId]))

        await coordinator.waitForPendingTargetedResyncForTesting()

        #expect(connectionCount.value == 2, "one connection for the op replay itself, one more (batched) for the targeted resync of both affected mailboxes")

        let refreshedInbox = try #require(try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: inboxId) })
        #expect(refreshedInbox.lastSyncedAt != nil, "the targeted resync should have run an incremental sync for INBOX")
        let refreshedArchive = try #require(try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: archiveId) })
        #expect(refreshedArchive.lastSyncedAt != nil, "...and for the self-healed Archive destination too")
    }

    @Test("replayOpQueue does not schedule a targeted resync when nothing applied")
    func replayOpQueueSkipsTargetedResyncWhenQueueEmpty() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount(host: "localhost")
        try await database.dbWriter.write { db in try account.insert(db) }

        let connectionCount = CallCounter()
        let coordinator = SyncCoordinator(
            database: database,
            sessionFactory: { config in
                connectionCount.increment()
                return FakeIMAPSession(config: config, script: FakeIMAPSession.Script())
            },
            targetedResyncDebounceInterval: 0.05
        )
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let result = try await coordinator.replayOpQueue(for: account, auth: auth)
        #expect(result.succeeded == 0)
        #expect(result.affectedMailboxIds.isEmpty)

        await coordinator.waitForPendingTargetedResyncForTesting()
        #expect(connectionCount.value == 0, "an empty queue shouldn't even open a connection for replay, let alone schedule a targeted resync")
    }
}
