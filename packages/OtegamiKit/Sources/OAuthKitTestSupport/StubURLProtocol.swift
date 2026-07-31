import Foundation

/// A `URLProtocol` stub (plan: "ローカル HTTP スタブ (URLProtocol モック)") that
/// dispatches each request to a per-test handler closure — used to script
/// the token endpoint's responses in `GoogleOAuthClientTests`/
/// `MicrosoftOAuthClientTests` without touching real servers.
///
/// `GooglePeopleAvatarClientTests` deliberately does **not** use this type —
/// see `PeopleAPIStubURLProtocol` (kept in `GoogleOAuthTests`, not moved
/// here) for why: Swift Testing parallelizes test functions including
/// across suites, and two suites racing on one static `handler` produced
/// real, reproducible cross-suite flakes.
public final class StubURLProtocol: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) public static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override public class func canInit(with request: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
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

    override public func stopLoading() {}

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
