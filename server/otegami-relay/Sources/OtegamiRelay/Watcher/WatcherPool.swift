import Foundation
import Logging
import NIOCore
import OtegamiRelayAPI
import ServiceLifecycle

/// One IMAP connection per watch, IDLE-ing (or STATUS-polling, for servers
/// without `IDLE`) for new mail and firing a push through `PushSending`
/// when `UIDNEXT` advances. Runs as a Hummingbird/ServiceLifecycle
/// `Service` alongside the HTTP server (`App.swift`), so its lifetime is
/// tied to the process and it gets a graceful-shutdown signal on `SIGTERM`.
///
/// Watch tasks are tracked in an actor-isolated dictionary so
/// `Routes/WatchRoutes.swift` can call `addWatch`/`removeWatch` the moment
/// a watch is created/deleted via the HTTP API, without waiting for the
/// pool's own reconciliation pass.
actor WatcherPool: Service {
    private let store: RelayStore
    private let pushSender: any PushSending
    private let eventLoopGroup: any EventLoopGroup
    private let logger: Logger

    /// Consecutive login failures at which a watch gives up entirely
    /// rather than continuing to retry (plan: "認証失敗連続で watch 自動停止") —
    /// avoids hammering an IMAP server (and potentially triggering its own
    /// rate limiting / account lockout) with credentials that are simply
    /// wrong.
    private let maxConsecutiveAuthFailures = 3

    /// RFC 2177 wants `IDLE` reissued at least every 29 minutes; the
    /// STATUS-polling fallback (servers without `IDLE`) uses a 5-minute
    /// interval. Both are constructor parameters — not hardcoded — purely
    /// so `WatcherPoolTests` can drive them down to milliseconds against
    /// `FakeIMAPServer` instead of actually waiting minutes.
    private let idleMaxWaitSeconds: Int64
    private let pollInterval: Duration
    /// CLAUDE-SECURITY F2 — re-validated on every (re)connect, not just
    /// once at watch creation; see `RelayNetworkPolicy`'s doc comment.
    /// Defaults to `.strict`; tests that intentionally dial loopback
    /// (`FakeIMAPServer`, dev-mailstack Dovecot on `localhost`) pass
    /// `.permissiveForTesting` explicitly.
    private let networkPolicy: RelayNetworkPolicy

    private var tasks: [String: Task<Void, Never>] = [:]

    init(
        store: RelayStore,
        pushSender: any PushSending,
        eventLoopGroup: any EventLoopGroup,
        logger: Logger,
        idleMaxWaitSeconds: Int64 = 29 * 60,
        pollInterval: Duration = .seconds(5 * 60),
        networkPolicy: RelayNetworkPolicy = .strict
    ) {
        self.store = store
        self.pushSender = pushSender
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.idleMaxWaitSeconds = idleMaxWaitSeconds
        self.pollInterval = pollInterval
        self.networkPolicy = networkPolicy
    }

    // MARK: - Service

    func run() async throws {
        let existing = (try? await store.listWatches()) ?? []
        for record in existing {
            start(watchId: record.id)
        }
        logger.info("WatcherPool started", metadata: ["watchCount": .stringConvertible(existing.count)])

        await withGracefulShutdownHandler {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        } onGracefulShutdown: { [weak self] in
            guard let self else { return }
            Task { await self.stopAll() }
        }
    }

    private func stopAll() {
        for (_, task) in tasks {
            task.cancel()
        }
        tasks.removeAll()
    }

    // MARK: - Dynamic add/remove (called from the HTTP routes)

    func addWatch(id: String) {
        start(watchId: id)
    }

    func removeWatch(id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    private func start(watchId: String) {
        guard tasks[watchId] == nil else { return }
        tasks[watchId] = Task { [weak self] in
            await self?.runWatchLoop(watchId: watchId)
        }
    }

    // MARK: - Per-watch loop

    private func runWatchLoop(watchId: String) async {
        var consecutiveAuthFailures = 0
        var backoffSeconds: UInt64 = 2

        while !Task.isCancelled {
            guard let record = try? await store.watch(id: watchId) else {
                logger.info("watch no longer exists, stopping", metadata: ["watchId": .string(watchId)])
                return
            }

            let client = MinimalIMAPClient(eventLoopGroup: eventLoopGroup)
            do {
                try await client.connect(
                    host: record.imapHost,
                    port: record.imapPort,
                    useTLS: record.imapUseTLS,
                    networkPolicy: networkPolicy
                )
                do {
                    try await client.login(username: record.imapUsername, password: record.secret)
                } catch {
                    await client.close()
                    consecutiveAuthFailures += 1
                    logger.warning(
                        "watch IMAP login failed",
                        metadata: [
                            "watchId": .string(watchId),
                            "attempt": .stringConvertible(consecutiveAuthFailures),
                        ]
                    )
                    if consecutiveAuthFailures >= maxConsecutiveAuthFailures {
                        logger.error(
                            "watch stopped after repeated auth failures",
                            metadata: ["watchId": .string(watchId)]
                        )
                        return
                    }
                    try? await Task.sleep(for: .seconds(Int64(backoffSeconds)))
                    backoffSeconds = min(backoffSeconds * 2, 300)
                    continue
                }

                consecutiveAuthFailures = 0
                backoffSeconds = 2

                let selectResult = try await client.select(mailbox: record.mailbox)
                var baselineUidNext: Int
                if let uidNext = selectResult.uidNext {
                    baselineUidNext = uidNext
                } else {
                    baselineUidNext = (try? await client.statusUIDNext(mailbox: record.mailbox)) ?? 0
                }
                let idleSupported = (try? await client.capabilitiesIncludeIdle()) ?? false

                logger.info(
                    "watch connected",
                    metadata: [
                        "watchId": .string(watchId),
                        "idle": .stringConvertible(idleSupported),
                        "uidNext": .stringConvertible(baselineUidNext),
                    ]
                )

                while !Task.isCancelled {
                    if idleSupported {
                        let gotExists = try await client.idle(mailbox: record.mailbox, maxWaitSeconds: idleMaxWaitSeconds)
                        guard gotExists else { continue }
                    } else {
                        try await Task.sleep(for: pollInterval)
                    }

                    let newUidNext = try await client.statusUIDNext(mailbox: record.mailbox)
                    if newUidNext > baselineUidNext {
                        baselineUidNext = newUidNext
                        await fire(record: record, uidNext: newUidNext)
                    }
                }
                await client.close()
                return
            } catch {
                await client.close()
                if Task.isCancelled { return }
                logger.warning(
                    "watch connection error, reconnecting",
                    metadata: ["watchId": .string(watchId), "error": .string(String(describing: error))]
                )
                try? await Task.sleep(for: .seconds(Int64(backoffSeconds)))
                backoffSeconds = min(backoffSeconds * 2, 300)
            }
        }
    }

    private func fire(record: RelayStore.WatchRecord, uidNext: Int) async {
        guard let target = try? await store.pushTarget(forDeviceId: record.deviceId) else {
            logger.debug(
                "watch fired but device has no push token yet",
                metadata: ["watchId": .string(record.id)]
            )
            return
        }
        do {
            try await pushSender.send(
                deviceToken: target.apnsToken,
                environment: target.environment,
                payload: PushNotificationPayload(accountId: record.accountId, uidNext: uidNext)
            )
        } catch {
            logger.warning(
                "push send failed",
                metadata: ["watchId": .string(record.id), "error": .string(String(describing: error))]
            )
        }
    }
}
