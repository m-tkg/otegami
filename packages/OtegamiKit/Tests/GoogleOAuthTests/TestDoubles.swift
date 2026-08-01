import Foundation
import OAuthKit
import OAuthKitTestSupport
@testable import GoogleOAuth

/// `FakeAuthorizationFlow`/`FakeRefreshTokenStore`/`FakeTokenRefresher` live
/// in `OAuthKitTestSupport` (shared, byte-identical fakes between
/// `GoogleOAuthTests` and `MicrosoftOAuthTests`) — these conformances/
/// aliases are the only `GoogleOAuth`-specific glue left: `FakeAuthorizationFlow`
/// conforms to the shared `OAuthKit.AuthorizationSessionRunning` base, but
/// `GoogleOAuthClient` expects this module's own local refinement (see that
/// protocol's doc comment for why it's a refinement, not a type alias).
///
/// `StubURLProtocol` below is **not** shared via `OAuthKitTestSupport` —
/// it was briefly consolidated there and immediately caused real,
/// reproducible cross-suite flakes (`GoogleOAuthClientTests` reading
/// `MicrosoftOAuthClientTests`' request body and vice versa): each
/// `@Suite(.serialized)` only serializes tests *within* that suite, but
/// Swift Testing still runs separate suites concurrently, and two suites
/// racing on one shared static `handler` corrupts both. Same failure mode
/// `PeopleAPIStubURLProtocol`'s own doc comment (in `GooglePeopleTests`)
/// already documents — this target's copy stays independent for the same
/// reason.
extension FakeAuthorizationFlow: GoogleOAuth.AuthorizationSessionRunning {}

/// `OAuthKitTestSupport.FakeTokenRefresher<Tokens>` is generic since
/// `GoogleTokenRefreshing` lives in this package, not `OAuthKitTestSupport`
/// (which can't depend on it without a circular dependency). This
/// conditional conformance plus the type alias below reproduce the original
/// concrete, non-generic `FakeTokenRefresher` every call site in this
/// target already uses (`FakeTokenRefresher { _ in fatalError(...) }`) —
/// fixing `Tokens` via the alias, rather than leaving every call site to
/// infer it from a `fatalError`-bodied closure alone, is what keeps those
/// call sites unchanged (a bare generic `FakeTokenRefresher { ... }` call
/// can't infer `Tokens` from a closure whose body is just `fatalError(...)`).
extension OAuthKitTestSupport.FakeTokenRefresher: GoogleTokenRefreshing where Tokens == GoogleOAuthTokens {}
typealias FakeTokenRefresher = OAuthKitTestSupport.FakeTokenRefresher<GoogleOAuthTokens>

// `PeopleAPIStubURLProtocol` moved to `GooglePeopleTests` (its own
// TestDoubles.swift) together with `GooglePeopleAvatarClientTests` when the
// `GooglePeople` target was split out of `GoogleOAuth` — see that file's
// doc comment for why it stays a separate stub type.

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
