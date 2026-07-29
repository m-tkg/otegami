import Foundation
import Testing
@testable import MicrosoftOAuth

@Suite("MicrosoftOAuthClient", .serialized)
struct MicrosoftOAuthClientTests {
    private let endpoints = MicrosoftOAuthEndpoints.standard(clientId: "test-client-id")
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeClient(
        sessionRunner: any AuthorizationSessionRunning,
        pkce: PKCE = PKCE(verifier: "fixed-verifier", challenge: "fixed-challenge"),
        state: String = "fixed-state"
    ) -> MicrosoftOAuthClient {
        MicrosoftOAuthClient(
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

    /// Builds an unsigned (`alg: none`) JWT with the given payload claims —
    /// enough to exercise `MicrosoftIDTokenClaims.decode`/`fetchUserEmail`,
    /// which deliberately never verifies the signature (see
    /// `MicrosoftIDTokenClaims`'s doc comment for why that's fine here: the
    /// token always comes straight from Azure AD's own token endpoint over
    /// TLS, never from an untrusted third party).
    private static func makeIDToken(claims: [String: Any]) -> String {
        func segment(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(segment(["alg": "none", "typ": "JWT"])).\(segment(claims)).signature"
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
                "id_token": Self.makeIDToken(claims: ["email": "someone@outlook.com"]),
            ])
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeClient(sessionRunner: flow)
        let tokens = try await client.requestAuthorization()

        #expect(tokens.accessToken == "access-1")
        #expect(tokens.refreshToken == "refresh-1")
        #expect(tokens.expiresAt == fixedNow.addingTimeInterval(3600))
        #expect(flow.lastCallbackURLScheme == endpoints.callbackURLScheme)
        #expect(try client.fetchUserEmail(idToken: tokens.idToken) == "someone@outlook.com")
    }

    @Test
    func requestAuthorizationPropagatesUserCancellation() async throws {
        let flow = FakeAuthorizationFlow(outcome: .failure(MicrosoftOAuthError.userCancelled))
        let client = makeClient(sessionRunner: flow)

        await #expect(throws: MicrosoftOAuthError.userCancelled) {
            _ = try await client.requestAuthorization()
        }
    }

    @Test
    func requestAuthorizationRejectsAMismatchedState() async throws {
        let callback = URL(string: "\(endpoints.redirectURI)?code=auth-code-123&state=wrong-state")!
        let flow = FakeAuthorizationFlow(outcome: .callback(callback))
        let client = makeClient(sessionRunner: flow)

        await #expect(throws: MicrosoftOAuthError.stateMismatch) {
            _ = try await client.requestAuthorization()
        }
    }

    @Test
    func requestAuthorizationSurfacesAnOAuthErrorParameter() async throws {
        let callback = URL(string: "\(endpoints.redirectURI)?error=access_denied&state=fixed-state")!
        let flow = FakeAuthorizationFlow(outcome: .callback(callback))
        let client = makeClient(sessionRunner: flow)

        await #expect(throws: MicrosoftOAuthError.authorizationDenied(reason: "access_denied")) {
            _ = try await client.requestAuthorization()
        }
    }

    @Test
    func requestAuthorizationRejectsACallbackWithNoCodeOrError() async throws {
        let callback = URL(string: "\(endpoints.redirectURI)?state=fixed-state")!
        let flow = FakeAuthorizationFlow(outcome: .callback(callback))
        let client = makeClient(sessionRunner: flow)

        await #expect(throws: MicrosoftOAuthError.missingAuthorizationCode) {
            _ = try await client.requestAuthorization()
        }
    }

    // MARK: - Refresh

    @Test
    func refreshReturnsANewAccessTokenAndKeepsTheOldRefreshTokenImplicit() async throws {
        let flow = FakeAuthorizationFlow(outcome: .failure(MicrosoftOAuthError.userCancelled))
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
        let flow = FakeAuthorizationFlow(outcome: .failure(MicrosoftOAuthError.userCancelled))
        StubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 400, body: [
                "error": "invalid_grant",
                "error_description": "AADSTS70008: The refresh token has expired.",
            ])
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeClient(sessionRunner: flow)
        await #expect(throws: MicrosoftOAuthError.invalidGrant) {
            _ = try await client.refresh(refreshToken: "dead-refresh")
        }
    }

    @Test
    func refreshMapsOtherTokenErrorsToTokenRequestFailed() async throws {
        let flow = FakeAuthorizationFlow(outcome: .failure(MicrosoftOAuthError.userCancelled))
        StubURLProtocol.handler = { request in
            self.jsonResponse(request.url!, status: 400, body: [
                "error": "invalid_client",
                "error_description": "Invalid client secret.",
            ])
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeClient(sessionRunner: flow)
        await #expect(throws: MicrosoftOAuthError.tokenRequestFailed(error: "invalid_client", description: "Invalid client secret.")) {
            _ = try await client.refresh(refreshToken: "whatever")
        }
    }

    // MARK: - fetchUserEmail(idToken:) — decoded from the id_token, no network call

    @Test
    func fetchUserEmailReadsTheEmailClaim() throws {
        let client = makeClient(sessionRunner: FakeAuthorizationFlow(outcome: .failure(MicrosoftOAuthError.userCancelled)))
        let idToken = Self.makeIDToken(claims: ["email": "someone@outlook.com", "preferred_username": "someone@outlook.com"])
        #expect(try client.fetchUserEmail(idToken: idToken) == "someone@outlook.com")
    }

    /// A personal Microsoft account without a verified email on file
    /// sometimes only populates `preferred_username` — see
    /// `MicrosoftOAuthClient.fetchUserEmail(idToken:)`'s doc comment.
    @Test
    func fetchUserEmailFallsBackToPreferredUsernameWhenEmailIsAbsent() throws {
        let client = makeClient(sessionRunner: FakeAuthorizationFlow(outcome: .failure(MicrosoftOAuthError.userCancelled)))
        let idToken = Self.makeIDToken(claims: ["preferred_username": "someone@outlook.com"])
        #expect(try client.fetchUserEmail(idToken: idToken) == "someone@outlook.com")
    }

    @Test
    func fetchUserEmailThrowsWhenNoIDTokenIsPresent() throws {
        let client = makeClient(sessionRunner: FakeAuthorizationFlow(outcome: .failure(MicrosoftOAuthError.userCancelled)))
        #expect(throws: MicrosoftOAuthError.missingEmail) {
            _ = try client.fetchUserEmail(idToken: nil)
        }
    }

    @Test
    func fetchUserEmailThrowsWhenTheIDTokenHasNeitherClaim() throws {
        let client = makeClient(sessionRunner: FakeAuthorizationFlow(outcome: .failure(MicrosoftOAuthError.userCancelled)))
        let idToken = Self.makeIDToken(claims: ["sub": "some-opaque-id"])
        #expect(throws: MicrosoftOAuthError.missingEmail) {
            _ = try client.fetchUserEmail(idToken: idToken)
        }
    }

    @Test
    func fetchUserEmailThrowsWhenTheTokenIsNotWellFormedJWT() throws {
        let client = makeClient(sessionRunner: FakeAuthorizationFlow(outcome: .failure(MicrosoftOAuthError.userCancelled)))
        #expect(throws: MicrosoftOAuthError.missingEmail) {
            _ = try client.fetchUserEmail(idToken: "not-a-jwt")
        }
    }
}

private extension URLRequest {
    /// Mirrors `GoogleOAuthTests`' identical helper — see that file's doc
    /// comment for why `httpBody` can be `nil` mid-`URLProtocol` handoff.
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
