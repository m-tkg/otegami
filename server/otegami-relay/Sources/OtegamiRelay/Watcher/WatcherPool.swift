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
    /// Task #175: exchanges a `.oauth` watch's stored refresh token for an
    /// access token right before `AUTHENTICATE XOAUTH2`. Defaults to a
    /// stub that always fails with `.missingClientId` — harmless for every
    /// existing `.password`-only test/deployment (this default is never
    /// reached unless a watch's `authType` is actually `.oauth`), and
    /// `App.swift` always passes a real `OAuthTokenExchanger` wired to
    /// `RelayConfiguration`'s client ids in production.
    private let oauthTokenExchanger: any OAuthTokenExchanging

    private var tasks: [String: Task<Void, Never>] = [:]

    init(
        store: RelayStore,
        pushSender: any PushSending,
        eventLoopGroup: any EventLoopGroup,
        logger: Logger,
        idleMaxWaitSeconds: Int64 = 29 * 60,
        pollInterval: Duration = .seconds(5 * 60),
        networkPolicy: RelayNetworkPolicy = .strict,
        oauthTokenExchanger: any OAuthTokenExchanging = UnconfiguredOAuthTokenExchanger()
    ) {
        self.store = store
        self.pushSender = pushSender
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.idleMaxWaitSeconds = idleMaxWaitSeconds
        self.pollInterval = pollInterval
        self.networkPolicy = networkPolicy
        self.oauthTokenExchanger = oauthTokenExchanger
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
                    switch record.authType {
                    case .password:
                        try await client.login(username: record.imapUsername, password: record.secret)
                    case .oauth:
                        // Task #175: `record.secret` is a refresh token
                        // for `.oauth` watches, never an IMAP password —
                        // exchange it for a short-lived access token
                        // (never persisted, see `OAuthTokenExchanging`'s
                        // doc comment) and authenticate via XOAUTH2
                        // instead of plain `LOGIN`.
                        guard let provider = record.provider else {
                            throw WatchAuthenticationError.missingOAuthProvider
                        }
                        let accessToken = try await oauthTokenExchanger.accessToken(
                            provider: provider,
                            refreshToken: record.secret
                        )
                        try await client.authenticateXOAuth2(username: record.imapUsername, accessToken: accessToken)
                    }
                } catch {
                    await client.close()
                    consecutiveAuthFailures += 1
                    let classification = Self.classifyAuthFailure(error)
                    logger.warning(
                        "watch authentication failed",
                        metadata: [
                            "watchId": .string(watchId),
                            "attempt": .stringConvertible(consecutiveAuthFailures),
                            "kind": .string(classification.errorKind.rawValue),
                        ]
                    )
                    // Task #175: an `invalid_grant` (dead refresh token) or
                    // a locally-detected configuration problem stops the
                    // watch on the very first occurrence — unlike a wrong
                    // IMAP password, retrying either can never succeed, so
                    // waiting for `maxConsecutiveAuthFailures` would only
                    // delay the app finding out. Every other case
                    // (including a wrong password) keeps the pre-#175
                    // "retry up to `maxConsecutiveAuthFailures` times"
                    // behavior.
                    let givingUp = classification.stopsImmediately || consecutiveAuthFailures >= maxConsecutiveAuthFailures
                    // Task #173: persist this so `GET /v1/watches` can tell
                    // the app which account's watch actually stopped —
                    // previously this was only visible in the relay's own
                    // logs, which is exactly the motivating 実機 report
                    // (a relay-side "3 watches, 1 auth-failed" log line
                    // with no way to tell *which* account from the app).
                    try? await store.recordWatchError(id: watchId, kind: classification.errorKind, stopping: givingUp)
                    if givingUp {
                        logger.error(
                            "watch stopped after authentication failure",
                            metadata: ["watchId": .string(watchId), "kind": .string(classification.errorKind.rawValue)]
                        )
                        return
                    }
                    try? await Task.sleep(for: .seconds(Int64(backoffSeconds)))
                    backoffSeconds = min(backoffSeconds * 2, 300)
                    continue
                }

                consecutiveAuthFailures = 0
                backoffSeconds = 2
                try? await store.markWatchConnected(id: watchId)

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
                // Task #173: recorded for display only — never `stopping`.
                // Unlike repeated auth failures, a connection/network
                // blip is expected to recover on its own, so this loop
                // keeps retrying with backoff regardless (unchanged
                // behavior); only the "last known problem" the app can
                // show changes.
                try? await store.recordWatchError(id: watchId, kind: .connectionError, stopping: false)
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

    // MARK: - Task #175: authentication failure classification

    /// How `runWatchLoop`'s authentication-failure catch block should
    /// react to a given error — which `WatchSummary.ErrorKind` to persist,
    /// and whether to give up on the very first occurrence rather than
    /// waiting for `maxConsecutiveAuthFailures`.
    private struct AuthFailureClassification {
        var errorKind: WatchSummary.ErrorKind
        var stopsImmediately: Bool
    }

    private static func classifyAuthFailure(_ error: Error) -> AuthFailureClassification {
        if let oauthError = error as? OAuthTokenExchangeError {
            switch oauthError {
            case .invalidGrant:
                // The refresh token itself is dead — no amount of
                // retrying an IMAP `AUTHENTICATE` will ever succeed again
                // without a fresh one from the app.
                return AuthFailureClassification(errorKind: .oauthTokenExpired, stopsImmediately: true)
            case .missingClientId, .tokenRequestFailed, .invalidResponse, .network:
                // Transient (network hiccup, endpoint outage) or an
                // operator configuration gap — either way, not something
                // the *user* can fix from the app, but also not
                // necessarily permanent, so this still gets
                // `maxConsecutiveAuthFailures` retries like a connection
                // error before giving up, rather than stopping instantly.
                return AuthFailureClassification(errorKind: .connectionError, stopsImmediately: false)
            }
        }
        if error is WatchAuthenticationError {
            // A watch record inconsistent with its own `authType`
            // (`.oauth` with no `provider`) — `WatchRoutes` validates this
            // at creation time, so reaching here means either a pre-
            // validation row (shouldn't exist) or a bug; retrying can
            // never fix data that's wrong at rest.
            return AuthFailureClassification(errorKind: .authFailure, stopsImmediately: true)
        }
        // IMAP `LOGIN`/`AUTHENTICATE` itself was rejected (wrong password,
        // or the IMAP server rejected an otherwise-valid access token) —
        // unchanged pre-#175 behavior: retried up to
        // `maxConsecutiveAuthFailures` times before stopping.
        return AuthFailureClassification(errorKind: .authFailure, stopsImmediately: false)
    }
}

/// A watch's `authType`/`provider` were inconsistent (`.oauth` with no
/// `provider`) — `WatchRoutes` validates this can't happen for any watch
/// created through the API, so this only exists as a safety net rather
/// than an expected runtime path.
private enum WatchAuthenticationError: Error {
    case missingOAuthProvider
}

/// `WatcherPool`'s default `oauthTokenExchanger` — every call fails with
/// `.missingClientId`, which `classifyAuthFailure` treats as a
/// `.connectionError` (retried with backoff, not stopped instantly). Never
/// reached by a `.password` watch (the only kind most tests/deployments
/// ever create); `App.swift` always supplies a real `OAuthTokenExchanger`
/// wired to `RelayConfiguration`'s client ids for `.oauth` watches in
/// production.
struct UnconfiguredOAuthTokenExchanger: OAuthTokenExchanging {
    func accessToken(provider: WatchAuth.Provider, refreshToken: String) async throws -> String {
        throw OAuthTokenExchangeError.missingClientId(provider)
    }
}
