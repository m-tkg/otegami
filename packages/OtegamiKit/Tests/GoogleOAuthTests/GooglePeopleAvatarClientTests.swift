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
