import Foundation
import Logging
import NIOPosix
import OtegamiRelayAPI
import Testing

@testable import OtegamiRelay

/// Opt-in: skipped (not failed) unless `OTEGAMI_TEST_IMAP_HOST` is set,
/// matching `packages/OtegamiKit`'s `MailTransportMailCoreTests` convention
/// (`docs/verify.md`). Run against dev/mailstack with:
///
///     make mailstack-up
///     OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter WatcherPoolRealDovecotIntegrationTests
///     make mailstack-down
///
/// **Why this exists in addition to `WatcherPoolTests` (`FakeIMAPServer`):**
/// this whole target's `FakeIMAPServer`-based unit tests passed the entire
/// time a real production bug shipped — `FakeIMAPServer` never
/// reproduces (a) an `IDLE` call actually reaching its `maxWaitSeconds`
/// deadline with the connection surviving intact for a subsequent command,
/// and (b) Dovecot's real "`* N EXISTS` then a separate `* 0 RECENT` line"
/// shape for new mail. A real Dovecot server was needed to catch both. See
/// `docs/verify.md`'s "otegami-relay: IDLE がタイムアウトで接続を壊す" entry
/// for the full writeup.
@Suite(
    "WatcherPool + MinimalIMAPClient (against real dev/mailstack Dovecot)",
    .enabled(if: RelayIMAPTestEnvironment.primary != nil, "set OTEGAMI_TEST_IMAP_HOST to run"),
    // Both tests below watch the same real `test1@otegami.test` INBOX
    // (there's only one seeded account to test against) and inject mail
    // into it via `doveadm save` - running them concurrently means one
    // test's injected mail also gets picked up by the other test's watch,
    // over-counting pushes. `FakeIMAPServer`-based tests don't have this
    // problem (each spins up its own isolated fake server).
    .serialized
)
struct WatcherPoolRealDovecotIntegrationTests {
    @Test("IDLE against a real server detects new mail delivered by another client and fires exactly one push")
    func idleDetectsRealNewMail() async throws {
        let env = try #require(RelayIMAPTestEnvironment.primary)
        defer { try? DoveadmHelper.restoreStandardFixtures() }

        let eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        let store = try await TestSupport.makeStore(eventLoopGroup: eventLoopGroup)
        let pushSender = FakePushSender()
        let watcherPool = WatcherPool(
            store: store,
            pushSender: pushSender,
            eventLoopGroup: eventLoopGroup,
            logger: Logger(label: "test"),
            idleMaxWaitSeconds: 120,
            pollInterval: .milliseconds(200)
        )

        let device = try await store.createDevice(apnsToken: "real-dovecot-token", environment: .sandbox)
        let watch = try await store.createWatch(
            deviceId: device.deviceId,
            request: CreateWatchRequest(
                accountId: "real-dovecot-account",
                imapHost: env.host,
                imapPort: env.port,
                imapUseTLS: false,
                imapUsername: env.username,
                auth: WatchAuth(secret: env.password),
                mailbox: "INBOX"
            )
        )
        await watcherPool.addWatch(id: watch.watchId)

        // Give the watch loop time to connect, LOGIN, SELECT, and enter IDLE
        // before another client delivers mail.
        try await Task.sleep(for: .seconds(2))

        try DoveadmHelper.save(
            user: env.username,
            content: """
            From: Integration Test <integration-test@otegami.test>\r
            To: \(env.username)\r
            Subject: WatcherPoolRealDovecotIntegrationTests probe\r
            Date: Mon, 1 Jan 2024 00:00:00 +0000\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            probe body\r
            """
        )

        var calls: [FakePushSender.Call] = []
        for _ in 0..<150 {
            calls = pushSender.calls
            if !calls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        #expect(calls.count == 1)
        #expect(calls.first?.payload.accountId == "real-dovecot-account")

        await watcherPool.removeWatch(id: watch.watchId)
        try await store.close()
    }

    @Test("a legitimate IDLE timeout (no mail within the window) doesn't break the connection - mail delivered afterwards is still detected")
    func idleTimeoutDoesNotBreakSubsequentDetection() async throws {
        let env = try #require(RelayIMAPTestEnvironment.primary)
        defer { try? DoveadmHelper.restoreStandardFixtures() }

        let eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        let store = try await TestSupport.makeStore(eventLoopGroup: eventLoopGroup)
        let pushSender = FakePushSender()
        // A deliberately short `idleMaxWaitSeconds` so the very first IDLE
        // cycle times out (no mail arrives in time) before we deliver
        // anything - this is exactly the RFC 2177 "reissue IDLE" case that
        // the bug in `MinimalIMAPClient.nextLine` (see docs/verify.md) used
        // to turn into a permanent "connection closed unexpectedly", never
        // to recover.
        let watcherPool = WatcherPool(
            store: store,
            pushSender: pushSender,
            eventLoopGroup: eventLoopGroup,
            logger: Logger(label: "test"),
            idleMaxWaitSeconds: 3,
            pollInterval: .milliseconds(200)
        )

        let device = try await store.createDevice(apnsToken: "real-dovecot-timeout-token", environment: .sandbox)
        let watch = try await store.createWatch(
            deviceId: device.deviceId,
            request: CreateWatchRequest(
                accountId: "real-dovecot-timeout-account",
                imapHost: env.host,
                imapPort: env.port,
                imapUseTLS: false,
                imapUsername: env.username,
                auth: WatchAuth(secret: env.password),
                mailbox: "INBOX"
            )
        )
        await watcherPool.addWatch(id: watch.watchId)

        // Let at least one full IDLE timeout (and, pre-fix, one poisoned
        // reconnect) happen with no mail delivered.
        try await Task.sleep(for: .seconds(6))

        try DoveadmHelper.save(
            user: env.username,
            content: """
            From: Integration Test <integration-test@otegami.test>\r
            To: \(env.username)\r
            Subject: WatcherPoolRealDovecotIntegrationTests post-timeout probe\r
            Date: Mon, 1 Jan 2024 00:00:00 +0000\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            probe body\r
            """
        )

        var calls: [FakePushSender.Call] = []
        for _ in 0..<150 {
            calls = pushSender.calls
            if !calls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        #expect(calls.count == 1)
        #expect(calls.first?.payload.accountId == "real-dovecot-timeout-account")

        await watcherPool.removeWatch(id: watch.watchId)
        try await store.close()
    }
}
