import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

@Suite("AccountSyncer initial sync — Task #187 auth-failure cooldown")
struct AccountSyncerAuthFailureCooldownTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test",
            email: "test1@otegami.test",
            authType: .password,
            imapHost: "localhost",
            imapPort: 1143,
            imapSecurity: .plain,
            imapUsername: "test1@otegami.test"
        )
    }

    // MARK: - Task #187: auth-failure cooldown (pure logic)

    @Test("no recorded auth failure means no cooldown")
    func authFailureCooldownRemainingIsNilWithoutAFailure() {
        #expect(AccountSyncer.authFailureCooldownRemaining(lastAuthFailureAt: nil, now: Date()) == nil)
    }

    @Test("a fresh auth failure reports the full cooldown remaining")
    func authFailureCooldownRemainingIsFullRightAfterAFailure() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let remaining = try #require(
            AccountSyncer.authFailureCooldownRemaining(lastAuthFailureAt: now, now: now)
        )
        #expect(remaining == 30 * 60)
    }

    @Test("a cooldown partway elapsed reports exactly what's left")
    func authFailureCooldownRemainingCountsDown() throws {
        let failedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let tenMinutesLater = failedAt.addingTimeInterval(10 * 60)
        let remaining = try #require(
            AccountSyncer.authFailureCooldownRemaining(lastAuthFailureAt: failedAt, now: tenMinutesLater)
        )
        #expect(remaining == 20 * 60)
    }

    @Test("once the cooldown fully elapses, retrying is allowed again")
    func authFailureCooldownRemainingIsNilOnceElapsed() {
        let failedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let exactlyAtCooldown = failedAt.addingTimeInterval(30 * 60)
        let wellPastCooldown = failedAt.addingTimeInterval(45 * 60)
        #expect(AccountSyncer.authFailureCooldownRemaining(lastAuthFailureAt: failedAt, now: exactlyAtCooldown) == nil)
        #expect(AccountSyncer.authFailureCooldownRemaining(lastAuthFailureAt: failedAt, now: wellPastCooldown) == nil)
    }

    /// End-to-end (not just the pure cooldown function): a `startIdleLoop`
    /// call right after an `.authenticationFailed` connect must not attempt
    /// a fresh LOGIN before the cooldown elapses — this is the actual bug
    /// (foreground-resume restarts `runIdleLoop` and used to reset its
    /// local backoff, immediately retrying) that motivated Task #187's app
    /// side fix. Uses `FakeIMAPSession.FlakyCallController` to fail the
    /// very first `connect()` with `.authenticationFailed`, then asserts no
    /// second `connect()` attempt lands within a short observation window
    /// even though the loop keeps running (it would, well within
    /// milliseconds, without the cooldown gate).
    @Test("startIdleLoop does not immediately retry after an authentication failure")
    func idleLoopDoesNotImmediatelyRetryAfterAuthFailure() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let connectCount = LockedBox(0)
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let script = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": []],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0)],
            // Every connect attempt fails authentication — if the loop
            // retried immediately (the pre-fix bug), `connectCount` would
            // climb well past 1 within the observation window below.
            failConnection: .authenticationFailed(underlyingDescription: "wrong password")
        )
        let syncer = AccountSyncer(
            account: account,
            database: database,
            sessionFactory: { config in
                connectCount.increment()
                return FakeIMAPSession(config: config, script: script)
            }
        )

        await syncer.startIdleLoop(auth: auth, onWake: {})

        // Generous relative to the loop's own pre-cooldown-gate short
        // backoff (5s/10s/...) so this would already have retried more
        // than once without the fix, while staying well under the 30-
        // minute cooldown itself.
        try await Task.sleep(for: .seconds(2))
        await syncer.stopIdleLoop()
        #expect(connectCount.value <= 1, "must not retry a LOGIN within the auth-failure cooldown window")
    }

    /// v1.14.2 UAF 修正 (3): `runIdleLoop`'s success path already called
    /// `session.disconnect()` before this fix, but a failure *after* a
    /// successful `connect()` — here, the `IDLE` stream itself throwing —
    /// used to fall straight into the `catch` block and drop `session`
    /// without ever disconnecting it (relying entirely on `deinit`/
    /// `SessionLingerBox` teardown instead of an orderly `LOGOUT`). Scripts
    /// a session that connects and selects INBOX fine but whose `idle`
    /// stream immediately throws, and asserts `disconnect()` still gets
    /// called exactly once for that connection.
    @Test("startIdleLoop disconnects the session even when the IDLE stream itself fails after a successful connect")
    func idleLoopDisconnectsAfterMidLoopFailure() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let recorder = FakeIMAPSession.CallRecorder()
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let script = FakeIMAPSession.Script(
            mailboxes: [inbox],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0)],
            // No `idleEvents`, so the stream fails immediately on the first
            // `IDLE` round — models a dropped connection right after LOGIN.
            failIdle: .connectionFailed(underlyingDescription: "idle dropped")
        )
        let syncer = AccountSyncer(
            account: account,
            database: database,
            sessionFactory: { config in FakeIMAPSession(config: config, script: script, recorder: recorder) }
        )

        await syncer.startIdleLoop(auth: auth, onWake: {})
        try await waitUntil(timeout: .seconds(5)) { recorder.disconnectCount >= 1 }
        await syncer.stopIdleLoop()
        #expect(recorder.disconnectCount == 1, "the mid-loop failure must not be disconnected twice")
    }

}

/// Same idea as `PooledIMAPSessionFactoryTests`'/`SyncCoordinatorTests
/// +SessionPooling.swift`'s identically-named, identically `private`
/// helper — condition-poll rather than a fixed sleep, since exactly when
/// the `Task.detached` disconnect (or the loop's own iteration) actually
/// runs isn't otherwise deterministic from the test's perspective.
private func waitUntil(timeout: Duration, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            throw WaitUntilTimeoutError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct WaitUntilTimeoutError: Error {}

/// Minimal `Sendable` mutable counter for the closure-captured assertion in
/// `idleLoopDoesNotImmediatelyRetryAfterAuthFailure` above (a plain `var`
/// can't be mutated from the non-isolated `sessionFactory` closure).
private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int
    init(_ value: Int) { _value = value }
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}
