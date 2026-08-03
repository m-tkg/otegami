import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

/// Phase 3 (IMAP 接続の再利用): `SyncCoordinator` に
/// `PooledIMAPSessionFactory.makeSessionFactory()` を `sessionFactory` として
/// 渡すだけで、既存の呼び出し側 (`syncAccountIncrementally`/
/// `replayOpQueue`) を一切変更せずに連続する呼び出しが接続を再利用できる
/// ことを検証する — `FakeIMAPSession.CallRecorder` の `connectCalls`/
/// `disconnectCount` (このタスクで追加) を使って、実際に何回
/// `connect(auth:)`/`disconnect()` が下位セッションへ届いたかを数える。
///
/// `idleSessionFactory` は別の生 factory であり続けるべき、という配線も
/// 合わせて検証する — `startIdleLoop` が `sessionFactory` (プール経由) を
/// 一切使わないことを、プールの `idleSessionCountForTesting` が0のまま
/// なことで確認する。
@Suite("SyncCoordinator + PooledIMAPSessionFactory")
struct SyncCoordinatorSessionPoolingTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            id: "account-1",
            displayName: "Test",
            email: "test1@otegami.test",
            authType: .password,
            imapHost: "localhost",
            imapPort: 1143,
            imapSecurity: .plain,
            imapUsername: "test1@otegami.test"
        )
    }

    private func makeInboxScript() -> FakeIMAPSession.Script {
        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        return FakeIMAPSession.Script(
            mailboxes: [inbox],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 1, highestModSeq: 0, messageCount: 0)]
        )
    }

    @Test("two consecutive syncAccountIncrementally calls through a pooled sessionFactory reuse one real connection")
    func consecutiveIncrementalSyncsReuseTheConnection() async throws {
        let database = try AppDatabase.makeInMemory()
        let recorder = FakeIMAPSession.CallRecorder()
        let script = makeInboxScript()
        let pool = PooledIMAPSessionFactory(sessionFactory: { config in
            FakeIMAPSession(config: config, script: script, recorder: recorder)
        })
        let coordinator = SyncCoordinator(database: database, sessionFactory: pool.makeSessionFactory())
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")

        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        _ = try await coordinator.syncAccountIncrementally(account, auth: auth)
        // `AccountSyncer.performIncrementalSync`'s `defer` disconnects via
        // a detached `Task { await session.disconnect() }` (unchanged by
        // this task — see that method's own defer), not an inline
        // `await`, so the give-back to the pool can still be in flight the
        // instant `syncAccountIncrementally` itself returns. Poll briefly
        // for it to land before issuing the second call — otherwise this
        // test would race the very thing it's trying to prove.
        try await waitUntil(timeout: .seconds(1)) { await pool.idleSessionCountForTesting == 1 }

        _ = try await coordinator.syncAccountIncrementally(account, auth: auth)
        // Same detached-disconnect race as above, now for the second
        // call's give-back.
        try await waitUntil(timeout: .seconds(1)) { await pool.idleSessionCountForTesting == 1 }

        // Both `syncAccountIncrementally` calls opened-and-closed a session
        // (`withIMAPSession`'s connect→...→disconnect shape, unchanged by
        // this task) — but only the *first* one actually reached the
        // underlying factory. The second reused the idle session the first
        // one's `disconnect()` returned to the pool.
        #expect(recorder.connectCount == 1)
        #expect(recorder.disconnectCount == 0)
        #expect(await pool.idleSessionCountForTesting == 1)
    }

    @Test("the foreground IDLE loop bypasses the pool even when sessionFactory is pooled")
    func idleLoopBypassesThePool() async throws {
        let database = try AppDatabase.makeInMemory()
        let poolRecorder = FakeIMAPSession.CallRecorder()
        let idleRecorder = FakeIMAPSession.CallRecorder()
        // Empty mailbox listing: `AccountSyncer.runIdleLoop` connects, lists
        // mailboxes, finds no INBOX, disconnects, and returns immediately —
        // enough to prove *which* factory `connect(auth:)` went through
        // without waiting through the loop's real backoff/idle-stream
        // machinery.
        let emptyScript = FakeIMAPSession.Script()
        let pool = PooledIMAPSessionFactory(sessionFactory: { config in
            FakeIMAPSession(config: config, script: emptyScript, recorder: poolRecorder)
        })
        let coordinator = SyncCoordinator(
            database: database,
            sessionFactory: pool.makeSessionFactory(),
            idleSessionFactory: { config in FakeIMAPSession(config: config, script: emptyScript, recorder: idleRecorder) }
        )
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        await coordinator.startIdleLoop(for: account, auth: auth)
        // The loop's first pass (no INBOX found) returns without ever
        // sleeping through a backoff — give it a brief moment to run.
        try await Task.sleep(for: .milliseconds(50))
        await coordinator.stopIdleLoop(for: account)

        #expect(idleRecorder.connectCount >= 1)
        #expect(poolRecorder.connectCount == 0)
        #expect(await pool.idleSessionCountForTesting == 0)
    }
}

/// Polls `condition` (checking every 5ms, up to `timeout`) until it returns
/// `true` — for asserting on the effect of a detached, un-awaited `Task`
/// (like `AccountSyncer.performIncrementalSync`'s disconnect-in-a-`defer`
/// pattern) without a fixed, potentially-flaky `Task.sleep`. Throws if
/// `condition` never becomes `true` within `timeout`.
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
