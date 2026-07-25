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
}
