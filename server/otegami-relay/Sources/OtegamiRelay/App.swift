import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import NIOPosix
import SQLiteNIO

/// Builds the router for the relay's HTTP API. Separated from `main` so
/// tests can exercise it without binding a real socket (`HealthTests`,
/// `DeviceRoutesTests`, `WatchRoutesTests`).
func buildRouter(
    store: RelayStore,
    watcherPool: WatcherPool,
    networkPolicy: RelayNetworkPolicy = .strict,
    deviceRegistrationSecret: String? = nil,
    logger: Logger = Logger(label: "otegami-relay")
) -> Router<BasicRequestContext> {
    let router = Router()
    router.get("/health") { _, _ in
        "ok"
    }
    DeviceRoutes.register(on: router, store: store, registrationSecret: deviceRegistrationSecret, logger: logger)
    WatchRoutes.register(on: router, store: store, watcherPool: watcherPool, networkPolicy: networkPolicy)
    return router
}

/// Picks the `PushSending` implementation: real APNs if every `APNS_*` env
/// var is configured, otherwise `ConsolePushSender` — see M9's constraint
/// on not having a `.p8` key yet and
/// `docker-compose.yml`/`docs/relay-deployment.md` for how a self-hoster
/// opts into real delivery.
func makePushSender(
    configuration: RelayConfiguration,
    httpClient: HTTPClient,
    logger: Logger
) -> any PushSending {
    guard let apns = configuration.apns else {
        logger.warning("APNS_* env vars not fully set; falling back to ConsolePushSender (no real push will be sent)")
        return ConsolePushSender(logger: logger)
    }
    guard let keyPEM = try? String(contentsOfFile: apns.keyPath, encoding: .utf8) else {
        logger.warning("could not read APNS_KEY_PATH (\(apns.keyPath)); falling back to ConsolePushSender")
        return ConsolePushSender(logger: logger)
    }
    return APNsSender(
        configuration: .init(privateKeyPEM: keyPEM, keyId: apns.keyId, teamId: apns.teamId, bundleId: apns.bundleId),
        httpClient: httpClient,
        logger: logger
    )
}

@main
struct OtegamiRelay {
    static func main() async throws {
        var logger = Logger(label: "otegami-relay")
        logger.logLevel = .info

        let configuration: RelayConfiguration
        do {
            configuration = try RelayConfiguration.fromEnvironment()
        } catch {
            logger.critical("configuration error: \(error)")
            throw error
        }

        // CLAUDE-SECURITY F2: surfaced once at startup too (not just on
        // every unauthenticated `POST /v1/devices`, see
        // `DeviceRoutes.authorizeRegistration`) so it's visible even on a
        // quiet relay nobody's actively probing yet.
        if configuration.deviceRegistrationSecret == nil {
            logger.warning(
                """
                RELAY_DEVICE_REGISTRATION_SECRET is not set — POST /v1/devices is open to \
                anyone who can reach this relay. See docs/relay-deployment.md.
                """
            )
        }
        if configuration.networkPolicy.allowPrivateNetworks {
            logger.warning(
                """
                RELAY_ALLOW_PRIVATE_IMAP_HOSTS is set — this relay will connect to \
                loopback/link-local/private IMAP hosts requested by any authenticated \
                watch. Only enable this if the relay's own network is trusted.
                """
            )
        }

        let crypto = try CredentialCrypto(base64Key: configuration.masterKeyBase64)
        let eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        let store = try await RelayStore.open(
            storage: .file(path: configuration.databasePath),
            threadPool: NIOThreadPool.singleton,
            eventLoop: eventLoopGroup.any(),
            crypto: crypto
        )

        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup))
        let pushSender = makePushSender(configuration: configuration, httpClient: httpClient, logger: logger)
        // Task #175: shares the same `HTTPClient` `pushSender`'s
        // `APNsSender` (when configured) uses — no reason for a second
        // connection pool just for token-endpoint calls.
        let oauthTokenExchanger = OAuthTokenExchanger(
            transport: AsyncHTTPClientOAuthTransport(httpClient: httpClient),
            googleClientId: configuration.googleOAuthClientId,
            microsoftClientId: configuration.microsoftOAuthClientId
        )
        if configuration.googleOAuthClientId == nil, configuration.microsoftOAuthClientId == nil {
            logger.info(
                """
                RELAY_GOOGLE_CLIENT_ID/RELAY_MICROSOFT_CLIENT_ID are not set — an .oauth \
                watch (Gmail/Outlook) can be created but will never authenticate. See \
                docs/relay-deployment.md.
                """
            )
        }
        let watcherPool = WatcherPool(
            store: store,
            pushSender: pushSender,
            eventLoopGroup: eventLoopGroup,
            logger: logger,
            networkPolicy: configuration.networkPolicy,
            oauthTokenExchanger: oauthTokenExchanger
        )

        let router = buildRouter(
            store: store,
            watcherPool: watcherPool,
            networkPolicy: configuration.networkPolicy,
            deviceRegistrationSecret: configuration.deviceRegistrationSecret,
            logger: logger
        )
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("0.0.0.0", port: configuration.port)),
            services: [watcherPool],
            logger: logger
        )
        try await app.runService()
        try? await httpClient.shutdown()
    }
}
