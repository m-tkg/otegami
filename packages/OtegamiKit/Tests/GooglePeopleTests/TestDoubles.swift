import Foundation

/// A `URLProtocol` stub that dispatches each request to a per-test handler
/// closure — used to script the People API's responses in
/// `GooglePeopleAvatarClientTests` without touching real Google servers.
///
/// This is `GooglePeopleTests`' own independent stub type (moved here
/// together with `GooglePeopleAvatarClientTests` when the `GooglePeople`
/// target was split out of `GoogleOAuth`) rather than a reuse of the
/// shared `OAuthKitTestSupport.StubURLProtocol` (used by
/// `GoogleOAuthClientTests`): Swift Testing parallelizes test functions
/// across suites, and two tests racing to set/read one shared static
/// `handler` produced real, reproducible cross-suite flakes (one test's
/// request occasionally hit another test's handler, or a handler cleared by
/// a `defer` mid-flight) back when both suites lived in the same target and
/// shared a stub type. Keeping this target's own stub type with its own
/// static `handler` preserves that isolation now that the two suites are in
/// separate test targets too, rather than relying on `swift test` never
/// running every target's tests in one shared process.
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
