import Foundation
import Testing
@testable import GoogleOAuth

@Suite("GooglePeopleAvatarClient", .serialized)
struct GooglePeopleAvatarClientTests {
    private func makeClient() -> GooglePeopleAvatarClient {
        GooglePeopleAvatarClient(session: PeopleAPIStubURLProtocol.makeSession())
    }

    private func jsonResponse(_ url: URL, status: Int, body: [String: Any]) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let data = try! JSONSerialization.data(withJSONObject: body)
        return (response, data)
    }

    // MARK: - lookupPhoto

    @Test
    func lookupPhotoReturnsTheMatchingNonDefaultPhotoURL() async throws {
        PeopleAPIStubURLProtocol.handler = { [self] request in
            #expect(request.url?.absoluteString.hasPrefix("https://people.googleapis.com/v1/otherContacts:search") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            return jsonResponse(request.url!, status: 200, body: [
                "results": [
                    [
                        "person": [
                            "emailAddresses": [["value": "someone@example.com"]],
                            "photos": [["url": "https://lh3.googleusercontent.com/a/abc", "default": false]],
                        ]
                    ]
                ],
            ])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.lookupPhoto(accessToken: "test-token", address: "someone@example.com")
        #expect(result == .found(photoURL: URL(string: "https://lh3.googleusercontent.com/a/abc")!))
    }

    @Test
    func lookupPhotoMatchesAddressCaseInsensitively() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 200, body: [
                "results": [
                    ["person": ["emailAddresses": [["value": "Someone@Example.com"]], "photos": [["url": "https://example.com/p.jpg"]]]]
                ],
            ])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.lookupPhoto(accessToken: "token", address: "someone@example.com")
        #expect(result == .found(photoURL: URL(string: "https://example.com/p.jpg")!))
    }

    @Test
    func lookupPhotoSkipsAPersonWhoseOnlyPhotoIsTheDefaultSilhouette() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 200, body: [
                "results": [
                    ["person": ["emailAddresses": [["value": "someone@example.com"]], "photos": [["url": "https://example.com/default.jpg", "default": true]]]]
                ],
            ])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.lookupPhoto(accessToken: "token", address: "someone@example.com")
        #expect(result == .notFound)
    }

    @Test
    func lookupPhotoReturnsNotFoundWhenNoResultMatchesTheAddress() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 200, body: ["results": []])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.lookupPhoto(accessToken: "token", address: "nobody@example.com")
        #expect(result == .notFound)
    }

    @Test
    func lookupPhotoReturnsInsufficientScopeOn403() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 403, body: ["error": ["code": 403, "status": "PERMISSION_DENIED"]])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.lookupPhoto(accessToken: "scoped-out-token", address: "someone@example.com")
        #expect(result == .insufficientScope)
    }

    @Test
    func lookupPhotoReturnsInsufficientScopeOn401() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 401, body: ["error": ["code": 401]])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.lookupPhoto(accessToken: "expired", address: "someone@example.com")
        #expect(result == .insufficientScope)
    }

    @Test
    func lookupPhotoReturnsUnavailableOnServerError() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 500, body: [:])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.lookupPhoto(accessToken: "token", address: "someone@example.com")
        #expect(result == .unavailable)
    }

    @Test
    func lookupPhotoReturnsUnavailableOnNetworkFailure() async throws {
        PeopleAPIStubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.lookupPhoto(accessToken: "token", address: "someone@example.com")
        #expect(result == .unavailable)
    }

    // MARK: - warmupSearchIndex

    /// Google's documented `otherContacts.search` warmup requirement: the
    /// resolver (`GoogleProfilePhotoAvatarResolver`, app layer) must send an
    /// empty-query request before its first real search per account. This
    /// test exercises `warmupSearchIndex(accessToken:)` itself — the piece
    /// that actually builds and sends that request — and asserts it hits
    /// the same `otherContacts:search` endpoint with an empty `query`.
    @Test
    func warmupSearchIndexSendsAnEmptyQueryRequest() async throws {
        // Assert inside the handler itself (rather than capturing into a
        // local `var`) — `PeopleAPIStubURLProtocol.handler` is a `@Sendable`
        // closure, and Swift 6 strict concurrency rejects mutating a
        // captured var from inside it (matches every other assertion-in-
        // handler test in this file, e.g.
        // `lookupPhotoReturnsTheMatchingNonDefaultPhotoURL` above).
        PeopleAPIStubURLProtocol.handler = { [self] request in
            #expect(request.url?.absoluteString.hasPrefix("https://people.googleapis.com/v1/otherContacts:search") == true)
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(items?.first(where: { $0.name == "query" })?.value == "")
            return jsonResponse(request.url!, status: 200, body: ["results": []])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        await client.warmupSearchIndex(accessToken: "test-token")
    }

    /// A warmup failure (network error, non-2xx, anything) must never
    /// throw or otherwise stop the caller — `GoogleProfilePhotoAvatarResolver
    /// .fetchFromGoogle` always attempts the real `lookupPhoto` search right
    /// after, regardless of how the warmup went. `warmupSearchIndex` itself
    /// has no return value to assert on for "did it swallow the error", so
    /// this test's real assertion is simply that awaiting it completes
    /// normally (doesn't throw/crash) even when every request fails.
    @Test
    func warmupSearchIndexNeverThrowsEvenWhenTheRequestFails() async throws {
        PeopleAPIStubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        await client.warmupSearchIndex(accessToken: "test-token")
        // No throw, no crash — reaching this line is the assertion.
    }

    // MARK: - downloadPhoto

    @Test
    func downloadPhotoReturnsTheBodyOn200() async throws {
        let expectedBytes = Data([0xFF, 0xD8, 0xFF])
        PeopleAPIStubURLProtocol.handler = { [self] request in
            #expect(request.url?.absoluteString == "https://example.com/p.jpg=s160")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, expectedBytes)
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let data = await client.downloadPhoto(url: URL(string: "https://example.com/p.jpg")!)
        #expect(data == expectedBytes)
    }

    @Test
    func downloadPhotoReturnsNilOnNotFound() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let data = await client.downloadPhoto(url: URL(string: "https://example.com/gone.jpg")!)
        #expect(data == nil)
    }

    // MARK: - Pure helpers

    @Test
    func searchURLIncludesTheReadMaskAndAddressQuery() throws {
        let url = try #require(GooglePeopleAvatarClient.searchURL(for: "someone@example.com"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        #expect(url.absoluteString.hasPrefix("https://people.googleapis.com/v1/otherContacts:search"))
        #expect(value("readMask") == "photos,emailAddresses")
        #expect(value("query") == "someone@example.com")
    }

    @Test
    func sizedPhotoURLAppendsASizeSuffixOnce() {
        let base = URL(string: "https://lh3.googleusercontent.com/a/abc")!
        #expect(GooglePeopleAvatarClient.sizedPhotoURL(base).absoluteString == "https://lh3.googleusercontent.com/a/abc=s160")

        let alreadySized = URL(string: "https://lh3.googleusercontent.com/a/abc=s96-c")!
        #expect(GooglePeopleAvatarClient.sizedPhotoURL(alreadySized) == alreadySized)
    }

    @Test
    func matchingPhotoURLStringReturnsNilForMalformedJSON() {
        let data = Data("not json".utf8)
        #expect(GooglePeopleAvatarClient.matchingPhotoURLString(in: data, address: "someone@example.com") == nil)
    }
}
