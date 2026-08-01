import Foundation
import OAuthKit
import OAuthKitTestSupport
@testable import MicrosoftOAuth

/// `FakeAuthorizationFlow`/`FakeRefreshTokenStore`/`FakeTokenRefresher` live
/// in `OAuthKitTestSupport` (shared, byte-identical fakes with
/// `GoogleOAuthTests`'s previous copies — see that target's
/// `TestDoubles.swift` for the full rationale of each). Only two pieces of
/// glue are needed here:
/// - `FakeAuthorizationFlow` conforms to the shared
///   `OAuthKit.AuthorizationSessionRunning` base, but `MicrosoftOAuthClient`
///   expects this module's own local refinement (see that protocol's doc
///   comment for why it's a refinement, not a type alias).
/// - `OAuthKitTestSupport.FakeTokenRefresher<Tokens>` is generic (since
///   `MicrosoftTokenRefreshing` lives in this package, not
///   `OAuthKitTestSupport`); fixing `Tokens` via a local type alias
///   (rather than leaving every call site to infer it) is what keeps this
///   target's existing `FakeTokenRefresher { _ in fatalError(...) }` call
///   sites unchanged — a bare generic call can't infer `Tokens` from a
///   closure whose body is just `fatalError(...)`.
///
/// `FakeRefreshTokenStore` needs no such glue — `RefreshTokenStoring` is
/// already the same shared protocol both providers use (see
/// `MicrosoftOAuth.RefreshTokenStoring`'s doc comment) — so this target
/// uses `OAuthKitTestSupport`'s copy directly.
///
/// `StubURLProtocol` below is deliberately **not** shared via
/// `OAuthKitTestSupport` — it briefly was, and immediately caused real,
/// reproducible cross-suite flakes (`MicrosoftOAuthClientTests` reading
/// `GoogleOAuthClientTests`' request body and vice versa): each
/// `@Suite(.serialized)` only serializes tests *within* that suite, but
/// Swift Testing still runs separate suites concurrently, and two suites
/// racing on one shared static `handler` corrupts both. Same failure mode
/// `PeopleAPIStubURLProtocol`'s own doc comment (in `GooglePeopleTests`)
/// already documents — this target's copy stays independent for the same
/// reason.
extension FakeAuthorizationFlow: MicrosoftOAuth.AuthorizationSessionRunning {}

extension OAuthKitTestSupport.FakeTokenRefresher: MicrosoftTokenRefreshing where Tokens == MicrosoftOAuthTokens {}
typealias FakeTokenRefresher = OAuthKitTestSupport.FakeTokenRefresher<MicrosoftOAuthTokens>

/// A `URLProtocol` stub — mirrors `GoogleOAuthTests.StubURLProtocol` (its own
/// independent copy, deliberately not shared — see the doc comment above).
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
