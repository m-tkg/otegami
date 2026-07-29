import Foundation
@testable import MicrosoftOAuth

/// Mirrors `GoogleOAuthTests.TestDoubles.swift` — see that file's doc
/// comments for the full rationale of each fake (identical here).
final class FakeAuthorizationFlow: AuthorizationSessionRunning, @unchecked Sendable {
    enum Outcome {
        case callback(URL)
        case failure(Error)
    }

    var outcome: Outcome
    private(set) var lastAuthorizationURL: URL?
    private(set) var lastCallbackURLScheme: String?

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func run(authorizationURL: URL, callbackURLScheme: String) async throws -> URL {
        lastAuthorizationURL = authorizationURL
        lastCallbackURLScheme = callbackURLScheme
        switch outcome {
        case .callback(let url): return url
        case .failure(let error): throw error
        }
    }
}

final class FakeRefreshTokenStore: RefreshTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private(set) var writeCount = 0
    private(set) var deleteCount = 0

    func write(_ refreshToken: String, accountId: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[accountId] = refreshToken
        writeCount += 1
    }

    func read(accountId: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[accountId]
    }

    func delete(accountId: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[accountId] = nil
        deleteCount += 1
    }

    func seed(_ refreshToken: String, accountId: String) {
        lock.lock(); defer { lock.unlock() }
        storage[accountId] = refreshToken
    }

    func currentValue(accountId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[accountId]
    }
}

final class FakeTokenRefresher: MicrosoftTokenRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var _refreshCallCount = 0
    var refreshCallCount: Int {
        lock.withLock { _refreshCallCount }
    }

    var handler: @Sendable (String) async throws -> MicrosoftOAuthTokens

    init(handler: @escaping @Sendable (String) async throws -> MicrosoftOAuthTokens) {
        self.handler = handler
    }

    func refresh(refreshToken: String) async throws -> MicrosoftOAuthTokens {
        lock.withLock { _refreshCallCount += 1 }
        return try await handler(refreshToken)
    }
}

/// `URLProtocol` stub — mirrors `GoogleOAuthTests.StubURLProtocol` (its own
/// doc comment explains why `GooglePeopleAvatarClientTests` needed a
/// *second*, independent stub type rather than sharing one: Swift Testing
/// parallelizes test functions, and two suites racing on one static
/// `handler` produced real flakes). `MicrosoftOAuthTests` is a separate
/// target from `GoogleOAuthTests` already (so there's no cross-target
/// static to share even if desired), but this type gets its own name here
/// regardless, matching that established pattern.
final class StubURLProtocol: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.lock.lock()
        let handler = StubURLProtocol.handler
        StubURLProtocol.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
