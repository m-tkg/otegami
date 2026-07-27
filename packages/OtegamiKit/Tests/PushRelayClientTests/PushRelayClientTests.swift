import Foundation
import OtegamiRelayAPI
import Testing

@testable import PushRelayClient

@Suite("PushRelayClient", .serialized)
struct PushRelayClientTests {
    private func makeClient() -> PushRelayClient {
        PushRelayClient(urlSession: StubURLProtocol.makeSession())
    }

    private func jsonResponse(_ url: URL, status: Int, body: Data) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    @Test("registerDevice posts to /v1/devices and decodes the 201 response")
    func registerDevice() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { [self] request in
            #expect(request.url?.absoluteString == "https://relay.example.com/v1/devices")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

            let sent = try JSONDecoder().decode(RegisterDeviceRequest.self, from: request.httpBody ?? request.bodyStreamData())
            #expect(sent.apnsToken == "device-token")
            #expect(sent.environment == .sandbox)

            let body = try JSONEncoder().encode(RegisterDeviceResponse(deviceId: "d1", deviceSecret: "s1"))
            return (jsonResponse(request.url!, status: 201, body: body), body)
        }
        defer { StubURLProtocol.handler = nil }

        let response = try await client.registerDevice(
            baseURL: URL(string: "https://relay.example.com")!,
            apnsToken: "device-token",
            environment: .sandbox
        )
        #expect(response.deviceId == "d1")
        #expect(response.deviceSecret == "s1")
    }

    @Test("registerDevice surfaces a non-201 response as .http with the decoded error body")
    func registerDeviceHTTPError() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let errorBody = try JSONEncoder().encode(RelayErrorResponse(error: "bad_request", message: "nope"))
            return (
                HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil)!,
                errorBody
            )
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await client.registerDevice(
                baseURL: URL(string: "https://relay.example.com")!,
                apnsToken: "t",
                environment: .sandbox
            )
            Issue.record("expected registerDevice to throw")
        } catch let PushRelayClient.PushRelayClientError.http(status, body) {
            #expect(status == 400)
            #expect(body?.error == "bad_request")
            #expect(body?.message == "nope")
        }
    }

    @Test("updateDeviceToken sends the bearer secret and PUTs to the device's token endpoint")
    func updateDeviceToken() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://relay.example.com/v1/devices/d1/token")
            #expect(request.httpMethod == "PUT")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer s1")
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.handler = nil }

        try await client.updateDeviceToken(
            baseURL: URL(string: "https://relay.example.com")!,
            deviceId: "d1",
            deviceSecret: "s1",
            apnsToken: "new-token",
            environment: .production
        )
    }

    @Test("createWatch posts the IMAP credential with the bearer secret and decodes the watch")
    func createWatch() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { [self] request in
            #expect(request.url?.absoluteString == "https://relay.example.com/v1/watches")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer s1")

            let sent = try JSONDecoder().decode(CreateWatchRequest.self, from: request.httpBody ?? request.bodyStreamData())
            #expect(sent.accountId == "account-1")
            #expect(sent.auth.secret == "app-password")

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let body = try encoder.encode(
                WatchResponse(watchId: "w1", accountId: "account-1", mailbox: "INBOX", createdAt: Date(timeIntervalSince1970: 0))
            )
            return (jsonResponse(request.url!, status: 201, body: body), body)
        }
        defer { StubURLProtocol.handler = nil }

        let response = try await client.createWatch(
            baseURL: URL(string: "https://relay.example.com")!,
            deviceSecret: "s1",
            request: CreateWatchRequest(
                accountId: "account-1",
                imapHost: "imap.example.com",
                imapPort: 993,
                imapUseTLS: true,
                imapUsername: "user@example.com",
                auth: WatchAuth(secret: "app-password")
            )
        )
        #expect(response.watchId == "w1")
        #expect(response.accountId == "account-1")
    }

    @Test("listWatches GETs with the bearer secret and decodes the watch list")
    func listWatches() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://relay.example.com/v1/watches")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer s1")

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let body = try encoder.encode(
                ListWatchesResponse(watches: [
                    WatchSummary(watchId: "w1", accountId: "account-1", imapHost: "imap.example.com", mailbox: "INBOX", createdAt: Date(timeIntervalSince1970: 0)),
                ])
            )
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, body)
        }
        defer { StubURLProtocol.handler = nil }

        let watches = try await client.listWatches(baseURL: URL(string: "https://relay.example.com")!, deviceSecret: "s1")
        #expect(watches.count == 1)
        #expect(watches[0].watchId == "w1")
        #expect(watches[0].accountId == "account-1")
        #expect(watches[0].imapHost == "imap.example.com")
    }

    @Test("deleteWatch DELETEs with the bearer secret")
    func deleteWatch() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://relay.example.com/v1/watches/w1")
            #expect(request.httpMethod == "DELETE")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer s1")
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.handler = nil }

        try await client.deleteWatch(baseURL: URL(string: "https://relay.example.com")!, deviceSecret: "s1", watchId: "w1")
    }

    @Test("a network-level failure surfaces as .network, not silently swallowed")
    func networkFailurePropagates() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await client.registerDevice(
                baseURL: URL(string: "https://relay.example.com")!,
                apnsToken: "t",
                environment: .sandbox
            )
            Issue.record("expected registerDevice to throw")
        } catch let PushRelayClient.PushRelayClientError.network(description) {
            #expect(!description.isEmpty)
        }
    }
}

private extension URLRequest {
    /// `httpBody` is `nil` for a request that went through `URLProtocol`'s
    /// `startLoading()` after being handed off by `URLSession` in some SDK
    /// versions (the body becomes a stream instead) — reconstructs it from
    /// `httpBodyStream` when that happens. Identical to `GoogleOAuthTests`'
    /// helper of the same name (see that file — not shared across test
    /// targets, SwiftPM test targets don't share sources).
    func bodyStreamData() -> Data {
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 { data.append(buffer, count: read) }
            else { break }
        }
        return data
    }
}
