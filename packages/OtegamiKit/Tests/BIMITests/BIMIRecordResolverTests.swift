import Foundation
import Testing
@testable import BIMI

/// `URLProtocol` stub matching this package's other network-client test
/// suites (e.g. `GooglePeopleAvatarClientTests`' `PeopleAPIStubURLProtocol`).
final class DoHStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
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
        configuration.protocolClasses = [DoHStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@Suite("BIMIRecordClient", .serialized)
struct BIMIRecordResolverTests {
    private func makeClient() -> BIMIRecordClient {
        BIMIRecordClient(session: DoHStubURLProtocol.makeSession())
    }

    private func jsonResponse(_ url: URL, status: Int, body: [String: Any]) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let data = try! JSONSerialization.data(withJSONObject: body)
        return (response, data)
    }

    @Test
    func resolveLogoURLQueriesTheDefaultBIMISubdomainForTheDomain() async throws {
        DoHStubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString.contains("name=default._bimi.example.com") == true)
            #expect(request.url?.absoluteString.contains("type=TXT") == true)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/dns-json")
            return self.jsonResponse(request.url!, status: 200, body: ["Status": 0, "Answer": []])
        }
        defer { DoHStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.resolveLogoURL(domain: "example.com")
        #expect(result == .notFound)
    }

    @Test
    func resolveLogoURLParsesASingleQuotedTXTRecord() async throws {
        DoHStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 200, body: [
                "Status": 0,
                "Answer": [["data": "\"v=BIMI1; l=https://example.com/logo.svg;\""]],
            ])
        }
        defer { DoHStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.resolveLogoURL(domain: "example.com")
        #expect(result == .found(URL(string: "https://example.com/logo.svg")!))
    }

    @Test
    func resolveLogoURLReassemblesAMultiSegmentTXTRecordWithoutInsertingASpace() async throws {
        // A long value split mid-URL across two quoted segments — Google's
        // DoH echoes these back space-separated, and naively replacing `"`
        // with nothing (leaving the space) would corrupt the URL.
        DoHStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 200, body: [
                "Status": 0,
                "Answer": [["data": "\"v=BIMI1; l=https://example.com/lo\" \"go.svg;\""]],
            ])
        }
        defer { DoHStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.resolveLogoURL(domain: "example.com")
        #expect(result == .found(URL(string: "https://example.com/logo.svg")!))
    }

    @Test
    func resolveLogoURLSkipsATXTRecordThatIsNotBIMITagged() async throws {
        DoHStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 200, body: [
                "Status": 0,
                "Answer": [
                    ["data": "\"v=spf1 include:_spf.example.com ~all\""],
                    ["data": "\"v=BIMI1; l=https://example.com/logo.svg;\""],
                ],
            ])
        }
        defer { DoHStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.resolveLogoURL(domain: "example.com")
        #expect(result == .found(URL(string: "https://example.com/logo.svg")!))
    }

    @Test
    func resolveLogoURLReturnsNotFoundOnNXDOMAIN() async throws {
        DoHStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 200, body: ["Status": 3])
        }
        defer { DoHStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.resolveLogoURL(domain: "nonexistent.example")
        #expect(result == .notFound)
    }

    @Test
    func resolveLogoURLReturnsUnavailableOnNetworkFailure() async throws {
        DoHStubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { DoHStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.resolveLogoURL(domain: "example.com")
        #expect(result == .unavailable)
    }

    @Test
    func resolveLogoURLRejectsANonHTTPSLogoURL() async throws {
        DoHStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 200, body: [
                "Status": 0,
                "Answer": [["data": "\"v=BIMI1; l=http://example.com/logo.svg;\""]],
            ])
        }
        defer { DoHStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.resolveLogoURL(domain: "example.com")
        #expect(result == .notFound)
    }

    // MARK: - Pure helpers

    @Test
    func logoURLFromTXTRecordDataParsesTheLTag() {
        let url = BIMIRecordClient.logoURL(fromTXTRecordData: "v=BIMI1; l=https://example.com/logo.svg; a=https://example.com/vmc.pem;")
        #expect(url == URL(string: "https://example.com/logo.svg"))
    }

    @Test
    func logoURLFromTXTRecordDataReturnsNilWithoutTheBIMIPrefix() {
        #expect(BIMIRecordClient.logoURL(fromTXTRecordData: "v=spf1 include:_spf.example.com ~all") == nil)
    }

    @Test
    func logoURLFromTXTRecordDataReturnsNilWhenThereIsNoLTag() {
        #expect(BIMIRecordClient.logoURL(fromTXTRecordData: "v=BIMI1;") == nil)
    }

    @Test
    func queryURLBuildsTheDefaultBIMISubdomain() {
        let url = BIMIRecordClient.queryURL(domain: "acme.example")
        #expect(url?.absoluteString.contains("name=default._bimi.acme.example") == true)
    }
}
