import Foundation
import Testing
import MailTransport
import OtegamiCore
@testable import SyncEngine

/// Phase 3 (IMAP 接続の再利用): `PooledIMAPSessionFactory`/`PooledIMAPSession`
/// のプール挙動 (checkout/giveBack/TTL失効/`[LIMIT]`破棄/再利用セッションの
/// 1回だけの張り替えリトライ) を、実接続を一切張らない `PoolFakeSession` で
/// 検証する。`FakeIMAPSession` (`AccountSyncer`/`MailboxSyncer` シナリオ
/// 用) は使わない — スクリプトが接続ごとに変わる必要がある (「1本目は死んで
/// いるが2本目は生きている」を表現する) ため、この専用の軽量ダブルの方が
/// シンプルになる。
@Suite("PooledIMAPSessionFactory")
struct PooledIMAPSessionFactoryTests {
    private let config = IMAPConfig(host: "imap.otegami.test", port: 993, security: .tls)
    private let auth = MailAuth.password(username: "person@otegami.test", password: "secret")

    @Test("connecting, disconnecting, then connecting again for the same account reuses the underlying connection")
    func reusesConnectionAcrossConsecutiveCheckouts() async throws {
        let recorder = PoolFakeSession.Recorder()
        let pool = PooledIMAPSessionFactory(sessionFactory: { config in
            PoolFakeSession(config: config, script: .init(), recorder: recorder)
        })

        let first = pool.makeSession(config: config)
        try await first.connect(auth: auth)
        await first.disconnect()

        let second = pool.makeSession(config: config)
        try await second.connect(auth: auth)
        await second.disconnect()

        // Only the first `connect(auth:)` actually reached the underlying
        // factory — the second reused the idle session `giveBack` pooled.
        #expect(recorder.connectCount == 1)
        // Neither ever got a real `disconnect()` — both cycles returned the
        // one underlying session to the pool instead of tearing it down.
        #expect(recorder.disconnectCount == 0)
        #expect(await pool.idleSessionCountForTesting == 1)
    }

    @Test("an idle session past its TTL is disconnected for real, and the next connect starts fresh")
    func idleSessionExpiresAfterTTL() async throws {
        let recorder = PoolFakeSession.Recorder()
        // 実時間の TTL 経過を待たない: `sleep` に即時 return する実装を
        // 注入し、返却の瞬間に失効タイマーが「経過済み」として走るように
        // する (`SyncRetryPolicy` の injected-sleeper パターン)。以前の
        // 「TTL 0.05s + 実時間 1s 待ち」は、CI ランナーの負荷次第で
        // `Task.sleep` ベースのタイマー発火が 9 秒以上遅れて flaky だった
        // (ci-app の実失敗例)。
        let pool = PooledIMAPSessionFactory(
            sessionFactory: { config in PoolFakeSession(config: config, script: .init(), recorder: recorder) },
            idleTTL: 0.05,
            sleep: { _ in }
        )

        let first = pool.makeSession(config: config)
        try await first.connect(auth: auth)
        await first.disconnect()

        // 失効は返却が起動する独立した `Task` — 即時 sleep でも「いつ
        // スケジュールされるか」までは決定的でないので、固定待ちではなく
        // 条件成立をポーリングで待つ。
        try await waitUntil(timeout: .seconds(5)) { await pool.idleSessionCountForTesting == 0 }
        #expect(recorder.disconnectCount == 1)

        let second = pool.makeSession(config: config)
        try await second.connect(auth: auth)
        await second.disconnect()

        // The TTL-expired session forced a brand-new real connection.
        #expect(recorder.connectCount == 2)
    }

    @Test("a session that hit a [LIMIT] rate-limit response is discarded, not returned to the pool")
    func rateLimitedSessionIsDiscardedNotPooled() async throws {
        let recorder = PoolFakeSession.Recorder()
        let script = PoolFakeSession.Script(
            failCapabilities: .serverError(underlyingDescription: "A87 NO [LIMIT] STATUS Rate limit hit.")
        )
        let pool = PooledIMAPSessionFactory(sessionFactory: { config in
            PoolFakeSession(config: config, script: script, recorder: recorder)
        })

        let first = pool.makeSession(config: config)
        try await first.connect(auth: auth)
        await #expect(throws: (any Error).self) {
            _ = try await first.capabilities()
        }
        await first.disconnect()

        // Rate-limited: disconnected for real, never pooled.
        #expect(recorder.disconnectCount == 1)
        #expect(await pool.idleSessionCountForTesting == 0)

        let second = pool.makeSession(config: config)
        try await second.connect(auth: auth)
        await second.disconnect()

        // The discarded session forced a fresh real connection.
        #expect(recorder.connectCount == 2)
    }

    @Test("a reused session's first operation failing with connectionFailed retries once against a fresh connection")
    func reusedSessionRetriesOnceOnConnectionFailure() async throws {
        let recorder = PoolFakeSession.Recorder()
        // The factory's *first* call yields a session whose `capabilities()`
        // always fails with `.connectionFailed` (models an idle connection
        // the server silently dropped between check-in and reuse); every
        // subsequent call yields a healthy session.
        let callCount = PoolFakeSession.CallCounter()
        let factory: PooledIMAPSessionFactory.SessionFactory = { config in
            let n = callCount.next()
            let script = PoolFakeSession.Script(
                failCapabilities: n == 1 ? .connectionFailed(underlyingDescription: "dropped") : nil
            )
            return PoolFakeSession(config: config, script: script, recorder: recorder)
        }
        let pool = PooledIMAPSessionFactory(sessionFactory: factory)

        let first = pool.makeSession(config: config)
        try await first.connect(auth: auth)
        await first.disconnect()

        let second = pool.makeSession(config: config)
        try await second.connect(auth: auth) // reuses the (secretly dead) first underlying session — no new connect yet.
        #expect(recorder.connectCount == 1)

        // The reused session's first operation fails with connectionFailed;
        // `PooledIMAPSession` should silently reconnect fresh and re-issue
        // this same call rather than letting the error propagate.
        let capabilities = try await second.capabilities()
        #expect(capabilities.isEmpty)
        #expect(recorder.connectCount == 2)
    }
}

/// Minimal `IMAPSessionProtocol` double purpose-built for
/// `PooledIMAPSessionFactoryTests` — only `connect`/`disconnect`/
/// `capabilities()` are exercised by the pool's own logic (checkout/
/// giveBack/retry/rate-limit discard), so every other requirement just
/// throws `.notImplemented`.
final actor PoolFakeSession: IMAPSessionProtocol {
    /// Thread-safe call counter, shared across however many `PoolFakeSession`
    /// instances a test's factory closure creates — lets a test script a
    /// *different* behavior for the Nth session the factory builds (e.g.
    /// "the first one is secretly dead, every one after that is healthy").
    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _connectCount = 0
        private var _disconnectCount = 0
        func recordConnect() {
            lock.lock(); _connectCount += 1; lock.unlock()
        }
        func recordDisconnect() {
            lock.lock(); _disconnectCount += 1; lock.unlock()
        }
        var connectCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _connectCount
        }
        var disconnectCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _disconnectCount
        }
    }

    struct Script: Sendable {
        var failConnection: MailTransportError?
        var failCapabilities: MailTransportError?
        var capabilitiesToReport: Set<IMAPCapability> = []

        init(failConnection: MailTransportError? = nil, failCapabilities: MailTransportError? = nil, capabilitiesToReport: Set<IMAPCapability> = []) {
            self.failConnection = failConnection
            self.failCapabilities = failCapabilities
            self.capabilitiesToReport = capabilitiesToReport
        }
    }

    private let script: Script
    private let recorder: Recorder?

    /// Satisfies `IMAPSessionProtocol`'s required initializer — never used
    /// by these tests, which always go through `init(config:script:recorder:)`
    /// via the pool's own factory closure (see `IMAPSessionPool.swift`'s
    /// `PooledIMAPSession.init(config:)` doc comment for why the protocol
    /// requires this at all).
    init(config: IMAPConfig) {
        self.script = Script()
        self.recorder = nil
    }

    init(config: IMAPConfig, script: Script, recorder: Recorder?) {
        self.script = script
        self.recorder = recorder
    }

    func connect(auth: MailAuth) async throws {
        recorder?.recordConnect()
        if let failConnection = script.failConnection {
            throw failConnection
        }
    }

    func disconnect() async {
        recorder?.recordDisconnect()
    }

    func capabilities() async throws -> Set<IMAPCapability> {
        if let failCapabilities = script.failCapabilities {
            throw failCapabilities
        }
        return script.capabilitiesToReport
    }

    func listMailboxes() async throws -> [MailboxInfo] { throw MailTransportError.notImplemented("listMailboxes") }
    func select(_ mailboxPath: String) async throws -> MailboxStatus { throw MailTransportError.notImplemented("select") }
    func createMailbox(path: String) async throws { throw MailTransportError.notImplemented("createMailbox") }
    func status(_ mailboxPath: String) async throws -> MailboxStatus { throw MailTransportError.notImplemented("status") }
    func fetchEnvelopes(mailboxPath: String, uids: UIDRange, batchSize: Int) async throws -> [FetchedEnvelope] {
        throw MailTransportError.notImplemented("fetchEnvelopes")
    }
    func fetchRecentEnvelopes(mailboxPath: String, count: Int, batchSize: Int, status: MailboxStatus) async throws -> [FetchedEnvelope] {
        throw MailTransportError.notImplemented("fetchRecentEnvelopes")
    }
    func fetchEnvelopes(mailboxPath: String, changedSince modSeq: UInt64) async throws -> ChangedSinceResult {
        throw MailTransportError.notImplemented("fetchEnvelopes(changedSince:)")
    }
    func fetchFlags(mailboxPath: String, changedSince modSeq: UInt64) async throws -> ChangedSinceFlagsResult {
        throw MailTransportError.notImplemented("fetchFlags(changedSince:)")
    }
    func searchExistingUIDs(mailboxPath: String, uids: UIDRange) async throws -> Set<UInt32> {
        throw MailTransportError.notImplemented("searchExistingUIDs")
    }
    func fetchFlags(mailboxPath: String, uids: UIDRange) async throws -> [UInt32: MessageFlags] {
        throw MailTransportError.notImplemented("fetchFlags(uids: UIDRange)")
    }
    func fetchFlags(mailboxPath: String, uids: UIDSet) async throws -> [UInt32: MessageFlags] {
        throw MailTransportError.notImplemented("fetchFlags(uids: UIDSet)")
    }
    func fetchBody(mailboxPath: String, uid: UInt32) async throws -> MessageBodyContent {
        throw MailTransportError.notImplemented("fetchBody")
    }
    func fetchMessageBody(mailboxPath: String, uid: UInt32, partId: String?) async throws -> Data {
        throw MailTransportError.notImplemented("fetchMessageBody")
    }
    func store(mailboxPath: String, change: FlagChange) async throws { throw MailTransportError.notImplemented("store") }
    func append(mailboxPath: String, messageData: Data, flags: MessageFlags) async throws -> UInt32? {
        throw MailTransportError.notImplemented("append")
    }
    func move(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {
        throw MailTransportError.notImplemented("move")
    }
    func copy(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {
        throw MailTransportError.notImplemented("copy")
    }
    func expunge(mailboxPath: String) async throws { throw MailTransportError.notImplemented("expunge") }
    nonisolated func idle(mailboxPath: String) -> AsyncThrowingStream<IdleEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: MailTransportError.notImplemented("idle"))
        }
    }
}

/// `SyncCoordinatorTests+SessionPooling.swift` の同名ヘルパーと同じもの
/// (どちらも `private` なファイルスコープ) — 非同期に完了する副作用を、
/// 固定の flaky な `Task.sleep` ではなく条件成立のポーリングで待つ。
/// `timeout` までに `condition` が真にならなければ throw。
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
