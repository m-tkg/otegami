import Foundation
@testable import GoogleOAuth

/// Stands in for `ASWebAuthenticationSessionRunner` (the plan's
/// "FakeAuthorizationFlow"): returns a canned callback URL (or throws a
/// canned error) instead of presenting any real UI, so `GoogleOAuthClientTests`
/// can drive `requestAuthorization()` end to end without
/// `AuthenticationServices`/a presentation anchor.
final class FakeAuthorizationFlow: AuthorizationSessionRunning, @unchecked Sendable {
    enum Outcome {
        case callback(URL)
        case failure(Error)
    }

    var outcome: Outcome
    /// Records what was actually requested, so a test can assert the
    /// authorization URL carried the right PKCE challenge/state/scope
    /// without needing `GoogleOAuthClient` to expose those internals
    /// directly.
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

/// A trivial in-memory `RefreshTokenStoring` — see that protocol's doc
/// comment for why tests never exercise the real Keychain-backed
/// `KeychainRefreshTokenStore`. `RefreshTokenStoring`'s methods are
/// synchronous (matching `KeychainRefreshTokenStore`'s synchronous
/// `Security` framework calls), so a plain lock-protected class is enough —
/// no actor hop, no risk of the async-bridging deadlocks a semaphore-based
/// actor wrapper could hit on the cooperative thread pool.
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

/// A closure-backed `GoogleTokenRefreshing` fake — lets `TokenStoreTests`
/// script exactly what a `refresh(refreshToken:)` call should return/throw
/// per invocation, without any `URLSession`/PKCE machinery.
final class FakeTokenRefresher: GoogleTokenRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var _refreshCallCount = 0
    var refreshCallCount: Int {
        lock.withLock { _refreshCallCount }
    }

    var handler: @Sendable (String) async throws -> GoogleOAuthTokens

    init(handler: @escaping @Sendable (String) async throws -> GoogleOAuthTokens) {
        self.handler = handler
    }

    func refresh(refreshToken: String) async throws -> GoogleOAuthTokens {
        lock.withLock { _refreshCallCount += 1 }
        return try await handler(refreshToken)
    }
}

/// A `URLProtocol` stub (plan: "ローカル HTTP スタブ (URLProtocol モック)") that
/// dispatches each request to a per-test handler closure — used to script
/// the token endpoint's/userinfo endpoint's responses in
/// `GoogleOAuthClientTests` without touching real Google servers.
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
