import Foundation
import Testing
@testable import GoogleOAuth

@Suite("GoogleOAuthClient", .serialized)
struct GoogleOAuthClientTests {
    private let endpoints = GoogleOAuthEndpoints.standard(clientId: "test-client.apps.googleusercontent.com")
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeClient(
        sessionRunner: any AuthorizationSessionRunning,
        pkce: PKCE = PKCE(verifier: "fixed-verifier", challenge: "fixed-challenge"),
        state: String = "fixed-state"
    ) -> GoogleOAuthClient {
        GoogleOAuthClient(
            endpoints: endpoints,
            sessionRunner: sessionRunner,
            urlSession: StubURLProtocol.makeSession(),
            pkceGenerator: { pkce },
            stateGenerator: { state },
            now: { self.fixedNow }
        )
    }

    private func jsonResponse(_ url: URL, status: Int, body: [String: Any]) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let data = try! JSONSerialization.data(withJSONObject: body)
        return (response, data)
    }

    // MARK: - Full flow: auth code received → token exchange

    @Test
    func requestAuthorizationExchangesTheCallbackCodeForTokens() async throws {
        let callback = URL(string: "\(endpoints.redirectURI)?code=auth-code-123&state=fixed-state")!
        let flow = FakeAuthorizationFlow(outcome: .callback(callback))

        StubURLProtocol.handler = { [self] request in
            #expect(request.url == endpoints.tokenEndpoint)
            let body = String(data: request.httpBody ?? request.bodyStreamData(), encoding: .utf8) ?? ""
            #expect(body.contains("grant_type=authorization_code"))
            #expect(body.contains("code=auth-code-123"))
            #expect(body.contains("code_verifier=fixed-verifier"))
            return jsonResponse(request.url!, status: 200, body: [
                "access_token": "access-1",
                "refresh_token": "refresh-1",
                "expires_in": 3600,
                "token_type": "Bearer",
            ])
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeClient(sessionRunner: flow)
        let tokens = try await client.requestAuthorization()

        #expect(tokens.accessToken == "access-1")
        #expect(tokens.refreshToken == "refresh-1")
        #expect(tokens.expiresAt == fixedNow.addingTimeInterval(3600))
        #expect(flow.lastCallbackURLScheme == endpoints.callbackURLScheme)
    }

    @Test
    func requestAuthorizationPropagatesUserCancellation() async throws {
        let flow = FakeAuthorizationFlow(outcome: .failure(GoogleOAuthError.userCancelled))
        let client = makeClient(sessionRunner: flow)

        await #expect(throws: GoogleOAuthError.userCancelled) {
            _ = try await client.requestAuthorization()
        }
    }

    @Test
    func requestAuthorizationRejectsAMismatchedState() async throws {
        let callback = URL(string: "\(endpoints.redirectURI)?code=auth-code-123&state=wrong-state")!
        let flow = FakeAuthorizationFlow(outcome: .callback(callback))
        let client = makeClient(sessionRunner: flow)

        await #expect(throws: GoogleOAuthError.stateMismatch) {
            _ = try await client.requestAuthorization()
        }
    }

    @Test
    func requestAuthorizationSurfacesAnOAuthErrorParameter() async throws {
        let callback = URL(string: "\(endpoints.redirectURI)?error=access_denied&state=fixed-state")!
        let flow = FakeAuthorizationFlow(outcome: .callback(callback))
        let client = makeClient(sessionRunner: flow)

        await #expect(throws: GoogleOAuthError.authorizationDenied(reason: "access_denied")) {
            _ = try await client.requestAuthorization()
        }
    }

    @Test
    func requestAuthorizationRejectsACallbackWithNoCodeOrError() async throws {
        let callback = URL(string: "\(endpoints.redirectURI)?state=fixed-state")!
        let flow = FakeAuthorizationFlow(outcome: .callback(callback))
        let client = makeClient(sessionRunner: flow)

        await #expect(throws: GoogleOAuthError.missingAuthorizationCode) {
            _ = try await client.requestAuthorization()
        }
    }

    // MARK: - Refresh

    @Test
    func refreshReturnsANewAccessTokenAndKeepsTheOldRefreshTokenImplicit() async throws {
        let flow = FakeAuthorizationFlow(outcome: .failure(GoogleOAuthError.userCancelled))
        StubURLProtocol.handler = { [self] request in
            let body = String(data: request.httpBody ?? request.bodyStreamData(), encoding: .utf8) ?? ""
            #expect(body.contains("grant_type=refresh_token"))
            #expect(body.contains("refresh_token=stored-refresh"))
            return jsonResponse(request.url!, status: 200, body: [
                "access_token": "access-2",
                "expires_in": 1800,
            ])
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeClient(sessionRunner: flow)
        let tokens = try await client.refresh(refreshToken: "stored-refresh")
        #expect(tokens.accessToken == "access-2")
        #expect(tokens.refreshToken == nil)
        #expect(tokens.expiresAt == fixedNow.addingTimeInterval(1800))
    }

    @Test
    func refreshMapsInvalidGrantToADistinctError() async throws {
        let flow = FakeAuthorizationFlow(outcome: .failure(GoogleOAuthError.userCancelled))
        StubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 400, body: [
                "error": "invalid_grant",
                "error_description": "Token has been expired or revoked.",
            ])
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeClient(sessionRunner: flow)
        await #expect(throws: GoogleOAuthError.invalidGrant) {
            _ = try await client.refresh(refreshToken: "dead-refresh")
        }
    }

    @Test
    func refreshMapsOtherTokenErrorsToTokenRequestFailed() async throws {
        let flow = FakeAuthorizationFlow(outcome: .failure(GoogleOAuthError.userCancelled))
        StubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 400, body: [
                "error": "invalid_client",
                "error_description": "Unauthorized client.",
            ])
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeClient(sessionRunner: flow)
        await #expect(throws: GoogleOAuthError.tokenRequestFailed(error: "invalid_client", description: "Unauthorized client.")) {
            _ = try await client.refresh(refreshToken: "whatever")
        }
    }

    // MARK: - userinfo (email discovery)

    @Test
    func fetchUserEmailReturnsTheAddressFromUserinfo() async throws {
        let flow = FakeAuthorizationFlow(outcome: .failure(GoogleOAuthError.userCancelled))
        StubURLProtocol.handler = { [self] request in
            #expect(request.url == endpoints.userInfoEndpoint)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            return jsonResponse(request.url!, status: 200, body: ["email": "someone@gmail.com"])
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeClient(sessionRunner: flow)
        let email = try await client.fetchUserEmail(accessToken: "access-token")
        #expect(email == "someone@gmail.com")
    }

    @Test
    func fetchUserEmailThrowsWhenTheResponseHasNoEmail() async throws {
        let flow = FakeAuthorizationFlow(outcome: .failure(GoogleOAuthError.userCancelled))
        StubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 200, body: [:])
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeClient(sessionRunner: flow)
        await #expect(throws: GoogleOAuthError.missingEmail) {
            _ = try await client.fetchUserEmail(accessToken: "access-token")
        }
    }
}

private extension URLRequest {
    /// `httpBody` is `nil` for a request that went through `URLProtocol`'s
    /// `startLoading()` after being handed off by `URLSession` in some SDK
    /// versions (the body becomes a stream instead) — this reconstructs it
    /// from `httpBodyStream` when that happens, so the body-content
    /// assertions above stay reliable regardless of which path a given
    /// OS/toolchain takes.
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
