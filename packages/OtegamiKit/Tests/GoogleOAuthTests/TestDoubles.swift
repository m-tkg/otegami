import Foundation
import OAuthKit
import OAuthKitTestSupport
@testable import GoogleOAuth

/// `FakeAuthorizationFlow`/`FakeRefreshTokenStore`/`FakeTokenRefresher`/
/// `StubURLProtocol` now live in `OAuthKitTestSupport` (shared,
/// byte-identical fakes between `GoogleOAuthTests` and
/// `MicrosoftOAuthTests`) — these conformances/aliases are the only
/// `GoogleOAuth`-specific glue left: `FakeAuthorizationFlow` conforms to the
/// shared `OAuthKit.AuthorizationSessionRunning` base, but
/// `GoogleOAuthClient` expects this module's own local refinement (see that
/// protocol's doc comment for why it's a refinement, not a type alias).
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

/// A `URLProtocol` stub that dispatches each request to a per-test handler
/// closure — used to script the token endpoint's/userinfo endpoint's
/// responses in `GoogleOAuthClientTests` without touching real Google
/// servers. Deliberately **not** the shared `OAuthKitTestSupport.StubURLProtocol`
/// (used by `GoogleOAuthClientTests` itself) — this second, independent stub
/// type exists solely for `GooglePeopleAvatarClientTests`. Swift Testing
/// parallelizes test functions (including across different `@Suite`s in the
/// same target) by default — two tests from the two different suites racing
/// to set/read one shared static `handler` produced real, reproducible
/// cross-suite flakes (one test's request occasionally hit another test's
/// handler, or a handler cleared by a `defer` mid-flight) when both suites
/// used the same type. Giving `GooglePeopleAvatarClientTests` its own stub
/// type with its own static `handler` removes the shared mutable state
/// entirely, rather than trying to serialize two independently-`.serialized`
/// suites against each other (Swift Testing's `.serialized` trait only
/// orders a suite's own children, not other suites).
final class PeopleAPIStubURLProtocol: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        PeopleAPIStubURLProtocol.lock.lock()
        let handler = PeopleAPIStubURLProtocol.handler
        PeopleAPIStubURLProtocol.lock.unlock()

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
        configuration.protocolClasses = [PeopleAPIStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
