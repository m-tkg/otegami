import Logging
import NIOPosix
import OtegamiRelayAPI
import Testing

@testable import OtegamiRelay

@Suite("WatcherPool + MinimalIMAPClient (against FakeIMAPServer)")
struct WatcherPoolTests {
    @Test("IDLE-supporting server: new mail wakes IDLE immediately and fires exactly one push")
    func idleFlowFiresPush() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        let store = try await TestSupport.makeStore(eventLoopGroup: eventLoopGroup)
        let fakeServer = FakeIMAPServer(eventLoopGroup: eventLoopGroup, initialExists: 5, initialUidNext: 6, supportsIdle: true)
        let port = try await fakeServer.start()
        let pushSender = FakePushSender()
        let watcherPool = WatcherPool(
            store: store,
            pushSender: pushSender,
            eventLoopGroup: eventLoopGroup,
            logger: Logger(label: "test"),
            idleMaxWaitSeconds: 3,
            pollInterval: .milliseconds(200),
            // `FakeIMAPServer` binds loopback on an OS-assigned ephemeral
            // port — legitimate for this in-process test, not the SSRF
            // threat `RelayNetworkPolicy.strict` (the production default)
            // defends against. See RelayNetworkPolicy's doc comment.
            networkPolicy: .permissiveForTesting
        )

        let device = try await store.createDevice(apnsToken: "device-token-abc", environment: .sandbox)
        let watch = try await store.createWatch(
            deviceId: device.deviceId,
            request: CreateWatchRequest(
                accountId: "account-1",
                imapHost: "127.0.0.1",
                imapPort: port,
                imapUseTLS: false,
                imapUsername: "user@example.com",
                auth: WatchAuth(secret: "password"),
                mailbox: "INBOX"
            )
        )
        await watcherPool.addWatch(id: watch.watchId)

        // Give the watch loop time to connect, LOGIN, SELECT, and enter IDLE.
        try await Task.sleep(for: .milliseconds(300))
        fakeServer.deliverNewMail()

        // Poll for the push to land rather than a single fixed sleep, to
        // keep the test both fast and non-flaky under load.
        var calls: [FakePushSender.Call] = []
        for _ in 0..<50 {
            calls = pushSender.calls
            if !calls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(calls.count == 1)
        #expect(calls.first?.deviceToken == "device-token-abc")
        #expect(calls.first?.environment == .sandbox)
        #expect(calls.first?.payload.accountId == "account-1")
        #expect(calls.first?.payload.uidNext == 7)

        await watcherPool.removeWatch(id: watch.watchId)
        await fakeServer.stop()
        try await store.close()
    }

    @Test("non-IDLE server: polling fallback still notices new mail and fires a push")
    func pollingFlowFiresPush() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        let store = try await TestSupport.makeStore(eventLoopGroup: eventLoopGroup)
        let fakeServer = FakeIMAPServer(eventLoopGroup: eventLoopGroup, initialExists: 2, initialUidNext: 3, supportsIdle: false)
        let port = try await fakeServer.start()
        let pushSender = FakePushSender()
        let watcherPool = WatcherPool(
            store: store,
            pushSender: pushSender,
            eventLoopGroup: eventLoopGroup,
            logger: Logger(label: "test"),
            idleMaxWaitSeconds: 3,
            pollInterval: .milliseconds(200),
            // `FakeIMAPServer` binds loopback on an OS-assigned ephemeral
            // port — legitimate for this in-process test, not the SSRF
            // threat `RelayNetworkPolicy.strict` (the production default)
            // defends against. See RelayNetworkPolicy's doc comment.
            networkPolicy: .permissiveForTesting
        )

        let device = try await store.createDevice(apnsToken: "poll-device-token", environment: .production)
        let watch = try await store.createWatch(
            deviceId: device.deviceId,
            request: CreateWatchRequest(
                accountId: "account-2",
                imapHost: "127.0.0.1",
                imapPort: port,
                imapUseTLS: false,
                imapUsername: "user@example.com",
                auth: WatchAuth(secret: "password"),
                mailbox: "INBOX"
            )
        )
        await watcherPool.addWatch(id: watch.watchId)

        // Let the watch loop connect and establish its UIDNEXT baseline
        // (via SELECT) before delivering mail — otherwise the bump would
        // already be reflected in that very baseline and no *delta* would
        // ever be observed.
        try await Task.sleep(for: .milliseconds(300))
        fakeServer.deliverNewMail()

        var calls: [FakePushSender.Call] = []
        for _ in 0..<50 {
            calls = pushSender.calls
            if !calls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(calls.count == 1)
        #expect(calls.first?.payload.accountId == "account-2")
        #expect(calls.first?.payload.uidNext == 4)
        #expect(calls.first?.environment == .production)

        await watcherPool.removeWatch(id: watch.watchId)
        await fakeServer.stop()
        try await store.close()
    }

    @Test("a legitimate IDLE timeout (no mail within the window) doesn't break the connection - mail delivered afterwards is still detected")
    func idleTimeoutThenLaterMailStillFiresPush() async throws {
        // Regression test for a real bug (see docs/verify.md's "otegami-relay:
        // IDLE がタイムアウトで接続を壊す" entry): `MinimalIMAPClient.idle`
        // hitting its own `maxWaitSeconds` deadline with no mail delivered
        // (the ordinary, expected RFC 2177 "reissue IDLE" case) used to
        // permanently break the connection's read side, turning every
        // subsequent read into a hard "connection closed unexpectedly" and
        // forcing a reconnect whose fresh `SELECT` silently re-baselined
        // UIDNEXT — swallowing any mail that arrived in the gap instead of
        // firing a push for it. This test deliberately lets at least one
        // IDLE cycle time out with *no* mail delivered before delivering
        // any, so it fails if that regresses.
        let eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        let store = try await TestSupport.makeStore(eventLoopGroup: eventLoopGroup)
        let fakeServer = FakeIMAPServer(eventLoopGroup: eventLoopGroup, initialExists: 5, initialUidNext: 6, supportsIdle: true)
        let port = try await fakeServer.start()
        let pushSender = FakePushSender()
        let watcherPool = WatcherPool(
            store: store,
            pushSender: pushSender,
            eventLoopGroup: eventLoopGroup,
            logger: Logger(label: "test"),
            idleMaxWaitSeconds: 1,
            pollInterval: .milliseconds(200),
            // `FakeIMAPServer` binds loopback on an OS-assigned ephemeral
            // port — legitimate for this in-process test, not the SSRF
            // threat `RelayNetworkPolicy.strict` (the production default)
            // defends against. See RelayNetworkPolicy's doc comment.
            networkPolicy: .permissiveForTesting
        )

        let device = try await store.createDevice(apnsToken: "timeout-device-token", environment: .sandbox)
        let watch = try await store.createWatch(
            deviceId: device.deviceId,
            request: CreateWatchRequest(
                accountId: "account-timeout",
                imapHost: "127.0.0.1",
                imapPort: port,
                imapUseTLS: false,
                imapUsername: "user@example.com",
                auth: WatchAuth(secret: "password"),
                mailbox: "INBOX"
            )
        )
        await watcherPool.addWatch(id: watch.watchId)

        // Let at least one full IDLE cycle time out (idleMaxWaitSeconds=1)
        // with no mail delivered at all - this is what used to poison the
        // connection. A generous margin here (well beyond the 1s deadline)
        // keeps this robust under the CPU contention of `swift test`'s
        // default parallel execution, which otherwise made this flaky.
        try await Task.sleep(for: .seconds(4))
        #expect(pushSender.calls.isEmpty, "no mail was delivered yet, so no push should have fired")

        fakeServer.deliverNewMail()

        var calls: [FakePushSender.Call] = []
        for _ in 0..<100 {
            calls = pushSender.calls
            if !calls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(calls.count == 1)
        #expect(calls.first?.payload.accountId == "account-timeout")
        #expect(calls.first?.payload.uidNext == 7)

        await watcherPool.removeWatch(id: watch.watchId)
        await fakeServer.stop()
        try await store.close()
    }

    @Test("Task #173: repeated IMAP login failures stop the watch and persist status=stopped/authFailure")
    func repeatedLoginFailuresStopTheWatchAndPersistStatus() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        let store = try await TestSupport.makeStore(eventLoopGroup: eventLoopGroup)
        let fakeServer = FakeIMAPServer(eventLoopGroup: eventLoopGroup, supportsIdle: true, rejectsLogin: true)
        let port = try await fakeServer.start()
        let pushSender = FakePushSender()
        let watcherPool = WatcherPool(
            store: store,
            pushSender: pushSender,
            eventLoopGroup: eventLoopGroup,
            logger: Logger(label: "test"),
            idleMaxWaitSeconds: 3,
            pollInterval: .milliseconds(200),
            // Loopback, same rationale as every other test in this file.
            networkPolicy: .permissiveForTesting
        )

        let device = try await store.createDevice(apnsToken: "tok", environment: .sandbox)
        let watch = try await store.createWatch(
            deviceId: device.deviceId,
            request: CreateWatchRequest(
                accountId: "account-auth-fail",
                imapHost: "127.0.0.1",
                imapPort: port,
                imapUseTLS: false,
                imapUsername: "user@example.com",
                auth: WatchAuth(secret: "wrong-password")
            )
        )
        await watcherPool.addWatch(id: watch.watchId)

        // `maxConsecutiveAuthFailures` (3) with the loop's own 2s/4s
        // backoff between attempts — poll rather than a single fixed
        // sleep to stay both correct and no slower than necessary.
        var summary: WatchSummary?
        for _ in 0..<100 {
            let summaries = try await store.listWatchSummaries(deviceId: device.deviceId)
            if summaries.first?.status == .stopped {
                summary = summaries.first
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        #expect(summary?.status == .stopped)
        #expect(summary?.lastErrorKind == .authFailure)
        #expect(summary?.lastErrorAt != nil)
        #expect(summary?.lastConnectedAt == nil, "login never succeeded, so this should never get set")
        #expect(pushSender.calls.isEmpty)

        await watcherPool.removeWatch(id: watch.watchId)
        await fakeServer.stop()
        try await store.close()
    }

    @Test("deleting a watch stops its loop: further mail doesn't fire a push")
    func removingWatchStopsFurtherPushes() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        let store = try await TestSupport.makeStore(eventLoopGroup: eventLoopGroup)
        let fakeServer = FakeIMAPServer(eventLoopGroup: eventLoopGroup, initialExists: 1, initialUidNext: 2, supportsIdle: true)
        let port = try await fakeServer.start()
        let pushSender = FakePushSender()
        let watcherPool = WatcherPool(
            store: store,
            pushSender: pushSender,
            eventLoopGroup: eventLoopGroup,
            logger: Logger(label: "test"),
            idleMaxWaitSeconds: 3,
            pollInterval: .milliseconds(200),
            // `FakeIMAPServer` binds loopback on an OS-assigned ephemeral
            // port — legitimate for this in-process test, not the SSRF
            // threat `RelayNetworkPolicy.strict` (the production default)
            // defends against. See RelayNetworkPolicy's doc comment.
            networkPolicy: .permissiveForTesting
        )

        let device = try await store.createDevice(apnsToken: "tok", environment: .sandbox)
        let watch = try await store.createWatch(
            deviceId: device.deviceId,
            request: CreateWatchRequest(
                accountId: "account-3",
                imapHost: "127.0.0.1",
                imapPort: port,
                imapUseTLS: false,
                imapUsername: "user@example.com",
                auth: WatchAuth(secret: "password")
            )
        )
        await watcherPool.addWatch(id: watch.watchId)
        try await Task.sleep(for: .milliseconds(300))

        try await store.deleteWatch(id: watch.watchId, deviceId: device.deviceId)
        await watcherPool.removeWatch(id: watch.watchId)
        try await Task.sleep(for: .milliseconds(200))

        fakeServer.deliverNewMail()
        try await Task.sleep(for: .milliseconds(500))

        #expect(pushSender.calls.isEmpty)

        await fakeServer.stop()
        try await store.close()
    }
}
