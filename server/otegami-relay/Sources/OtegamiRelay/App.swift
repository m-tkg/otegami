import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import NIOPosix
import SQLiteNIO

/// Builds the router for the relay's HTTP API. Separated from `main` so
/// tests can exercise it without binding a real socket (`HealthTests`,
/// `DeviceRoutesTests`, `WatchRoutesTests`).
func buildRouter(store: RelayStore, watcherPool: WatcherPool) -> Router<BasicRequestContext> {
    let router = Router()
    router.get("/health") { _, _ in
        "ok"
    }
    DeviceRoutes.register(on: router, store: store)
    WatchRoutes.register(on: router, store: store, watcherPool: watcherPool)
    return router
}

/// Picks the `PushSending` implementation: real APNs if every `APNS_*` env
/// var is configured, otherwise `ConsolePushSender` — see M9's constraint
/// on not having a `.p8` key yet (`PENDING.md`) and
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
        let watcherPool = WatcherPool(store: store, pushSender: pushSender, eventLoopGroup: eventLoopGroup, logger: logger)

        let router = buildRouter(store: store, watcherPool: watcherPool)
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
