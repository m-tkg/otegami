import Foundation
import Testing
@testable import GooglePeople

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

    // MARK: - fetchOtherContactsPhotoIndex

    @Test
    func fetchOtherContactsPhotoIndexReturnsAnIndexOfNonDefaultPhotos() async throws {
        PeopleAPIStubURLProtocol.handler = { [self] request in
            #expect(request.url?.absoluteString.hasPrefix("https://people.googleapis.com/v1/otherContacts") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            return jsonResponse(request.url!, status: 200, body: [
                "otherContacts": [
                    [
                        "emailAddresses": [["value": "someone@example.com"]],
                        "photos": [["url": "https://lh3.googleusercontent.com/a/abc", "default": false]],
                    ]
                ],
            ])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.fetchOtherContactsPhotoIndex(accessToken: "test-token")
        #expect(result == .success(["someone@example.com": URL(string: "https://lh3.googleusercontent.com/a/abc")!]))
    }

    @Test
    func fetchOtherContactsPhotoIndexRequestsBothContactAndProfileSources() async throws {
        PeopleAPIStubURLProtocol.handler = { [self] request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let sources = items.filter { $0.name == "sources" }.compactMap(\.value)
            #expect(sources == ["READ_SOURCE_TYPE_CONTACT", "READ_SOURCE_TYPE_PROFILE"])
            #expect(items.first(where: { $0.name == "readMask" })?.value == "emailAddresses,photos")
            return jsonResponse(request.url!, status: 200, body: ["otherContacts": []])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        _ = await client.fetchOtherContactsPhotoIndex(accessToken: "test-token")
    }

    @Test
    func fetchOtherContactsPhotoIndexNormalizesAddressesCaseInsensitively() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 200, body: [
                "otherContacts": [
                    ["emailAddresses": [["value": " Someone@Example.com "]], "photos": [["url": "https://example.com/p.jpg"]]]
                ],
            ])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.fetchOtherContactsPhotoIndex(accessToken: "token")
        #expect(result == .success(["someone@example.com": URL(string: "https://example.com/p.jpg")!]))
    }

    @Test
    func fetchOtherContactsPhotoIndexSkipsAPersonWhoseOnlyPhotoIsTheDefaultSilhouette() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 200, body: [
                "otherContacts": [
                    ["emailAddresses": [["value": "someone@example.com"]], "photos": [["url": "https://example.com/default.jpg", "default": true]]]
                ],
            ])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.fetchOtherContactsPhotoIndex(accessToken: "token")
        #expect(result == .success([:]))
    }

    @Test
    func fetchOtherContactsPhotoIndexPrefersAProfileSourcedPhotoOverAContactSourcedOne() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 200, body: [
                "otherContacts": [
                    [
                        "emailAddresses": [["value": "someone@example.com"]],
                        "photos": [
                            ["url": "https://example.com/contact.jpg", "default": false, "metadata": ["source": ["type": "CONTACT"]]],
                            ["url": "https://example.com/profile.jpg", "default": false, "metadata": ["source": ["type": "PROFILE"]]],
                        ],
                    ]
                ],
            ])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.fetchOtherContactsPhotoIndex(accessToken: "token")
        #expect(result == .success(["someone@example.com": URL(string: "https://example.com/profile.jpg")!]))
    }

    @Test
    func fetchOtherContactsPhotoIndexFollowsNextPageTokenAndMergesResults() async throws {
        PeopleAPIStubURLProtocol.handler = { [self] request in
            let pageToken = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pageToken" })?.value
            if pageToken == nil {
                return jsonResponse(request.url!, status: 200, body: [
                    "otherContacts": [
                        ["emailAddresses": [["value": "first@example.com"]], "photos": [["url": "https://example.com/first.jpg"]]]
                    ],
                    "nextPageToken": "page-2",
                ])
            }
            #expect(pageToken == "page-2")
            return jsonResponse(request.url!, status: 200, body: [
                "otherContacts": [
                    ["emailAddresses": [["value": "second@example.com"]], "photos": [["url": "https://example.com/second.jpg"]]]
                ],
            ])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.fetchOtherContactsPhotoIndex(accessToken: "token")
        #expect(result == .success([
            "first@example.com": URL(string: "https://example.com/first.jpg")!,
            "second@example.com": URL(string: "https://example.com/second.jpg")!,
        ]))
    }

    @Test
    func fetchOtherContactsPhotoIndexReturnsInsufficientScopeOn403() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 403, body: ["error": ["code": 403, "status": "PERMISSION_DENIED"]])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.fetchOtherContactsPhotoIndex(accessToken: "scoped-out-token")
        #expect(result == .insufficientScope)
    }

    @Test
    func fetchOtherContactsPhotoIndexReturnsInsufficientScopeOn401() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 401, body: ["error": ["code": 401]])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.fetchOtherContactsPhotoIndex(accessToken: "expired")
        #expect(result == .insufficientScope)
    }

    @Test
    func fetchOtherContactsPhotoIndexReturnsUnavailableOnServerError() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 500, body: [:])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.fetchOtherContactsPhotoIndex(accessToken: "token")
        #expect(result == .unavailable)
    }

    @Test
    func fetchOtherContactsPhotoIndexReturnsUnavailableOnNetworkFailure() async throws {
        PeopleAPIStubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.fetchOtherContactsPhotoIndex(accessToken: "token")
        #expect(result == .unavailable)
    }

    @Test
    func fetchOtherContactsPhotoIndexReturnsUnavailableWhenALaterPageFails() async throws {
        PeopleAPIStubURLProtocol.handler = { [self] request in
            let pageToken = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pageToken" })?.value
            if pageToken == nil {
                return jsonResponse(request.url!, status: 200, body: [
                    "otherContacts": [
                        ["emailAddresses": [["value": "first@example.com"]], "photos": [["url": "https://example.com/first.jpg"]]]
                    ],
                    "nextPageToken": "page-2",
                ])
            }
            return jsonResponse(request.url!, status: 500, body: [:])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.fetchOtherContactsPhotoIndex(accessToken: "token")
        // The whole index is discarded, not just the failed page — see
        // `fetchPhotoIndex`'s doc comment on why a partial index is never
        // returned.
        #expect(result == .unavailable)
    }

    // MARK: - fetchConnectionsPhotoIndex

    @Test
    func fetchConnectionsPhotoIndexHitsTheConnectionsEndpointWithPersonFields() async throws {
        PeopleAPIStubURLProtocol.handler = { [self] request in
            #expect(request.url?.absoluteString.hasPrefix("https://people.googleapis.com/v1/people/me/connections") == true)
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.first(where: { $0.name == "personFields" })?.value == "emailAddresses,photos")
            return jsonResponse(request.url!, status: 200, body: [
                "connections": [
                    ["emailAddresses": [["value": "saved@example.com"]], "photos": [["url": "https://example.com/saved.jpg"]]]
                ],
            ])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.fetchConnectionsPhotoIndex(accessToken: "token")
        #expect(result == .success(["saved@example.com": URL(string: "https://example.com/saved.jpg")!]))
    }

    @Test
    func fetchConnectionsPhotoIndexReturnsInsufficientScopeOn403() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 403, body: ["error": ["code": 403, "status": "PERMISSION_DENIED"]])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let result = await client.fetchConnectionsPhotoIndex(accessToken: "scoped-out-token")
        #expect(result == .insufficientScope)
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

    // MARK: - Diagnostics outcome (Task #42「アバター診断」)

    @Test
    func fetchOtherContactsIndexOutcomeReportsEntryAndPhotoCountsOnSuccess() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 200, body: [
                "otherContacts": [
                    ["emailAddresses": [["value": "photo@example.com"]], "photos": [["url": "https://example.com/p.jpg"]]],
                    ["emailAddresses": [["value": "nophoto@example.com"]]],
                ],
            ])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let outcome = await client.fetchOtherContactsIndexOutcome(accessToken: "token")
        #expect(outcome.result == .success(["photo@example.com": URL(string: "https://example.com/p.jpg")!]))
        #expect(outcome.diagnostics.httpStatus == 200)
        #expect(outcome.diagnostics.pagesFetched == 1)
        #expect(outcome.diagnostics.entriesFetched == 2)
        #expect(outcome.diagnostics.entriesWithPhoto == 1)
        #expect(outcome.diagnostics.discarded == false)
    }

    @Test
    func fetchOtherContactsIndexOutcomeReportsDiscardWhenALaterPageFails() async throws {
        PeopleAPIStubURLProtocol.handler = { [self] request in
            let pageToken = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pageToken" })?.value
            if pageToken == nil {
                return jsonResponse(request.url!, status: 200, body: [
                    "otherContacts": [
                        ["emailAddresses": [["value": "first@example.com"]], "photos": [["url": "https://example.com/first.jpg"]]]
                    ],
                    "nextPageToken": "page-2",
                ])
            }
            return jsonResponse(request.url!, status: 500, body: ["error": "boom, and someone@example.com is in here too"])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let outcome = await client.fetchOtherContactsIndexOutcome(accessToken: "token")
        #expect(outcome.result == .unavailable)
        #expect(outcome.diagnostics.httpStatus == 500)
        #expect(outcome.diagnostics.pagesFetched == 1)
        #expect(outcome.diagnostics.entriesFetched == 1)
        #expect(outcome.diagnostics.entriesWithPhoto == 1)
        #expect(outcome.diagnostics.discarded == true)
        #expect(outcome.diagnostics.discardReason?.contains("1件") == true)
        #expect(outcome.diagnostics.errorBodySnippet?.contains("boom") == true)
    }

    @Test
    func fetchOtherContactsIndexOutcomeReportsNetworkErrorDescription() async throws {
        PeopleAPIStubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let outcome = await client.fetchOtherContactsIndexOutcome(accessToken: "token")
        #expect(outcome.result == .unavailable)
        #expect(outcome.diagnostics.networkErrorDescription != nil)
        #expect(outcome.diagnostics.discarded == false)
    }

    // MARK: - fetchSelfPhotoIndexOutcome (Task #42「自分のプロフィール写真」)

    @Test
    func fetchSelfPhotoIndexOutcomeHitsPeopleMeAndMapsEveryAliasToTheSamePhoto() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString.hasPrefix("https://people.googleapis.com/v1/people/me") == true)
            #expect(request.url?.absoluteString.contains("people/me/connections") == false)
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.first(where: { $0.name == "personFields" })?.value == "emailAddresses,photos")
            return self.jsonResponse(request.url!, status: 200, body: [
                "emailAddresses": [["value": "me@example.com"], ["value": "alias@example.com"]],
                "photos": [["url": "https://example.com/me.jpg", "default": false]],
            ])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let outcome = await client.fetchSelfPhotoIndexOutcome(accessToken: "token")
        #expect(outcome.result == .success([
            "me@example.com": URL(string: "https://example.com/me.jpg")!,
            "alias@example.com": URL(string: "https://example.com/me.jpg")!,
        ]))
        #expect(outcome.diagnostics.httpStatus == 200)
        #expect(outcome.diagnostics.entriesFetched == 1)
        #expect(outcome.diagnostics.entriesWithPhoto == 1)
    }

    @Test
    func fetchSelfPhotoIndexOutcomeReturnsSuccessWithEmptyIndexWhenNoPhoto() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 200, body: ["emailAddresses": [["value": "me@example.com"]]])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let outcome = await client.fetchSelfPhotoIndexOutcome(accessToken: "token")
        #expect(outcome.result == .success([:]))
        #expect(outcome.diagnostics.entriesWithPhoto == 0)
    }

    @Test
    func fetchSelfPhotoIndexOutcomeReturnsInsufficientScopeOn403() async throws {
        PeopleAPIStubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 403, body: ["error": ["code": 403]])
        }
        defer { PeopleAPIStubURLProtocol.handler = nil }

        let client = makeClient()
        let outcome = await client.fetchSelfPhotoIndexOutcome(accessToken: "token")
        #expect(outcome.result == .insufficientScope)
        #expect(outcome.diagnostics.httpStatus == 403)
    }

    // MARK: - Pure helpers

    @Test
    func pageURLIncludesRepeatedSourcesAndFieldsParam() throws {
        let url = try #require(GooglePeopleAvatarClient.pageURL(baseURL: URL(string: "https://people.googleapis.com/v1/otherContacts")!, fieldsParamName: "readMask", pageToken: nil))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        #expect(url.absoluteString.hasPrefix("https://people.googleapis.com/v1/otherContacts"))
        #expect(values("readMask") == ["emailAddresses,photos"])
        #expect(values("sources") == ["READ_SOURCE_TYPE_CONTACT", "READ_SOURCE_TYPE_PROFILE"])
        #expect(values("pageToken").isEmpty)
    }

    @Test
    func pageURLIncludesThePageTokenWhenGiven() throws {
        let url = try #require(GooglePeopleAvatarClient.pageURL(baseURL: URL(string: "https://people.googleapis.com/v1/otherContacts")!, fieldsParamName: "readMask", pageToken: "abc"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first(where: { $0.name == "pageToken" })?.value == "abc")
    }

    @Test
    func sizedPhotoURLAppendsASizeSuffixOnce() {
        let base = URL(string: "https://lh3.googleusercontent.com/a/abc")!
        #expect(GooglePeopleAvatarClient.sizedPhotoURL(base).absoluteString == "https://lh3.googleusercontent.com/a/abc=s160")

        let alreadySized = URL(string: "https://lh3.googleusercontent.com/a/abc=s96-c")!
        #expect(GooglePeopleAvatarClient.sizedPhotoURL(alreadySized) == alreadySized)
    }

    @Test
    func parsePageReturnsNilForMalformedJSON() {
        let data = Data("not json".utf8)
        #expect(GooglePeopleAvatarClient.parsePage(data, itemsKey: .otherContacts) == nil)
    }
}
