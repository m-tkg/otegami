import Crypto
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import OtegamiRelayAPI
import SQLiteNIO

@testable import OtegamiRelay

/// Shared test scaffolding: an in-memory `RelayStore` + `WatcherPool`
/// wired to a `FakePushSender`, matching what `App.swift` wires up for
/// real, minus the HTTP listener and real APNs/IMAP.
enum TestSupport {
    /// Matches `RequestContext.requestDecoder`'s default
    /// (`.iso8601` dates) — the routes' actual response bodies use it, so
    /// any test decoding a `WatchResponse` (which has a `createdAt: Date`)
    /// needs to match rather than relying on `JSONDecoder()`'s
    /// `.deferredToDate` default.
    static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func makeStore(eventLoopGroup: any EventLoopGroup) async throws -> RelayStore {
        let crypto = CredentialCrypto(key: .init(size: .bits256))
        return try await RelayStore.open(
            storage: .memory,
            threadPool: .singleton,
            eventLoop: eventLoopGroup.any(),
            crypto: crypto
        )
    }

    /// Opens an in-memory store + a `WatcherPool` wired to a
    /// `FakePushSender`, runs `body`, then closes the store — every test
    /// goes through this rather than repeating the setup/teardown
    /// (`SQLiteConnection` asserts if left open past deinit, so forgetting
    /// the teardown crashes the test process rather than just failing).
    static func withStore<T: Sendable>(
        _ body: @Sendable (RelayStore, WatcherPool, FakePushSender) async throws -> T
    ) async throws -> T {
        let eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        let store = try await makeStore(eventLoopGroup: eventLoopGroup)
        let pushSender = FakePushSender()
        let watcherPool = WatcherPool(
            store: store,
            pushSender: pushSender,
            eventLoopGroup: eventLoopGroup,
            logger: Logger(label: "test")
        )
        do {
            let result = try await body(store, watcherPool, pushSender)
            try await store.close()
            return result
        } catch {
            try? await store.close()
            throw error
        }
    }
}

/// Task #175: a scripted `OAuthTokenExchanging` for `WatcherPoolTests`'
/// OAuth-watch tests — either always succeeds with a fixed access token, or
/// always throws a fixed `OAuthTokenExchangeError`, per `behavior`. Never
/// makes a real network call, unlike `OAuthTokenExchanger` — that type's
/// own HTTP-parsing logic is covered separately by
/// `OAuthTokenExchangerTests` against a mocked `OAuthHTTPTransport`.
final class FakeOAuthTokenExchanger: OAuthTokenExchanging, @unchecked Sendable {
    enum Behavior {
        case succeed(accessToken: String)
        case fail(OAuthTokenExchangeError)
    }

    private let lock = NIOLock()
    private var _calls: [(provider: WatchAuth.Provider, refreshToken: String)] = []
    private let behavior: Behavior

    var calls: [(provider: WatchAuth.Provider, refreshToken: String)] {
        lock.withLock { _calls }
    }

    init(behavior: Behavior = .succeed(accessToken: "fake-access-token")) {
        self.behavior = behavior
    }

    func accessToken(provider: WatchAuth.Provider, refreshToken: String) async throws -> String {
        lock.withLock { _calls.append((provider, refreshToken)) }
        switch behavior {
        case .succeed(let accessToken):
            return accessToken
        case .fail(let error):
            throw error
        }
    }
}

/// Records every call instead of sending anything — `WatcherPoolTests`
/// assert against this rather than a real (or console-logging) sender.
final class FakePushSender: PushSending, @unchecked Sendable {
    struct Call: Equatable {
        var deviceToken: String
        var environment: RegisterDeviceRequest.Environment
        var payload: PushNotificationPayload
    }

    private let lock = NIOLock()
    private var _calls: [Call] = []

    var calls: [Call] {
        lock.withLock { _calls }
    }

    func send(
        deviceToken: String,
        environment: RegisterDeviceRequest.Environment,
        payload: PushNotificationPayload
    ) async throws {
        lock.withLock {
            _calls.append(Call(deviceToken: deviceToken, environment: environment, payload: payload))
        }
    }
}
