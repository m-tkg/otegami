import Foundation
import OAuthKit

/// Orchestrates Outlook.com/Office 365's Authorization Code + PKCE (S256)
/// flow end to end — mirrors `GoogleOAuth.GoogleOAuthClient`. See that
/// type's doc comment for the overall design (`URLSession` injected for
/// testability, etc.); differences from Google are called out below.
public actor MicrosoftOAuthClient: MicrosoftTokenRefreshing {
    private let endpoints: MicrosoftOAuthEndpoints
    private let urlSession: URLSession
    private let sessionRunner: any AuthorizationSessionRunning
    private let pkceGenerator: @Sendable () -> PKCE
    private let stateGenerator: @Sendable () -> String
    private let now: @Sendable () -> Date

    public init(
        endpoints: MicrosoftOAuthEndpoints,
        sessionRunner: any AuthorizationSessionRunning,
        urlSession: URLSession = .shared,
        pkceGenerator: @escaping @Sendable () -> PKCE = { PKCE.generate() },
        stateGenerator: @escaping @Sendable () -> String = { MicrosoftOAuthClient.randomState() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.endpoints = endpoints
        self.urlSession = urlSession
        self.sessionRunner = sessionRunner
        self.pkceGenerator = pkceGenerator
        self.stateGenerator = stateGenerator
        self.now = now
    }

    /// Runs the full interactive flow: presents the account picker, waits
    /// for the redirect, exchanges the resulting code for tokens. Throws
    /// `MicrosoftOAuthError.userCancelled` if the user dismisses the sheet,
    /// `.stateMismatch`/`.missingAuthorizationCode`/`.authorizationDenied`
    /// for a malformed or rejected callback, or a token-exchange error.
    public func requestAuthorization() async throws -> MicrosoftOAuthTokens {
        let pkce = pkceGenerator()
        let state = stateGenerator()
        let url = endpoints.authorizationURL(pkce: pkce, state: state)
        let callbackURL = try await sessionRunner.run(
            authorizationURL: url,
            callbackURLScheme: endpoints.callbackURLScheme
        )
        let code = try Self.authorizationCode(from: callbackURL, expectedState: state)
        return try await exchangeCode(code, verifier: pkce.verifier)
    }

    public func exchangeCode(_ code: String, verifier: String) async throws -> MicrosoftOAuthTokens {
        var parameters: [String: String] = [
            "client_id": endpoints.clientId,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": endpoints.redirectURI,
            "scope": endpoints.scope,
        ]
        return try await requestTokens(parameters: &parameters, isRefresh: false)
    }

    public func refresh(refreshToken: String) async throws -> MicrosoftOAuthTokens {
        var parameters: [String: String] = [
            "client_id": endpoints.clientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "scope": endpoints.scope,
        ]
        return try await requestTokens(parameters: &parameters, isRefresh: true)
    }

    /// Reads the signed-in account's email straight out of the id_token's
    /// claims (`email`, falling back to `preferred_username` — Azure AD
    /// sometimes only populates the latter for a personal Microsoft
    /// account, since `email` technically requires the account to have a
    /// verified email address on file). Unlike
    /// `GoogleOAuthClient.fetchUserEmail(accessToken:)`, this needs no
    /// extra network round trip: the `openid email` scope
    /// (`MicrosoftOAuthEndpoints.scope`) is exactly what makes Azure AD
    /// include these claims in the token response's `id_token` in the
    /// first place, so by the time `tokens.idToken` exists, the identity
    /// info is already sitting right there. Throws
    /// `MicrosoftOAuthError.missingEmail` if the token has no `idToken`, it
    /// doesn't parse as a JWT, or neither claim is present.
    /// `nonisolated` — this is a pure function of its argument (no actor
    /// state touched), so callers (`AppEnvironment.requestMicrosoftAuthorization`,
    /// and every test in `MicrosoftOAuthClientTests`) can call it
    /// synchronously without an `await`/actor hop, matching how a plain
    /// value-returning helper reads at every call site.
    public nonisolated func fetchUserEmail(idToken: String?) throws -> String {
        guard let idToken, let claims = MicrosoftIDTokenClaims.decode(idToken) else {
            throw MicrosoftOAuthError.missingEmail
        }
        if let email = claims.email, !email.isEmpty { return email }
        if let preferredUsername = claims.preferredUsername, !preferredUsername.isEmpty { return preferredUsername }
        throw MicrosoftOAuthError.missingEmail
    }

    // MARK: - Token endpoint

    private func requestTokens(parameters: inout [String: String], isRefresh: Bool) async throws -> MicrosoftOAuthTokens {
        var request = URLRequest(url: endpoints.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(parameters)

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw MicrosoftOAuthError.invalidTokenResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            if let errorBody = try? JSONDecoder().decode(MicrosoftTokenErrorResponse.self, from: data) {
                if isRefresh, errorBody.error == "invalid_grant" {
                    throw MicrosoftOAuthError.invalidGrant
                }
                throw MicrosoftOAuthError.tokenRequestFailed(error: errorBody.error, description: errorBody.errorDescription)
            }
            throw MicrosoftOAuthError.invalidTokenResponse
        }

        let decoder = JSONDecoder()
        guard let success = try? decoder.decode(MicrosoftTokenSuccessResponse.self, from: data) else {
            throw MicrosoftOAuthError.invalidTokenResponse
        }
        return MicrosoftOAuthTokens(
            accessToken: success.accessToken,
            refreshToken: success.refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(success.expiresIn)),
            scope: success.scope,
            idToken: success.idToken
        )
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await urlSession.data(for: request)
        } catch let error as MicrosoftOAuthError {
            throw error
        } catch {
            throw MicrosoftOAuthError.network(underlyingDescription: "\(error)")
        }
    }

    // MARK: - Callback parsing

    static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        if let error = value("error") {
            throw MicrosoftOAuthError.authorizationDenied(reason: error)
        }
        guard value("state") == expectedState else {
            throw MicrosoftOAuthError.stateMismatch
        }
        guard let code = value("code"), !code.isEmpty else {
            throw MicrosoftOAuthError.missingAuthorizationCode
        }
        return code
    }

    public static func randomState() -> String {
        PKCE.base64URLEncode(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
    }

    static func formEncode(_ parameters: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = parameters.map { key, value -> String in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}

/// Mirrors `GoogleOAuth.GoogleTokenRefreshing` — narrow protocol
/// `MicrosoftTokenStore` depends on instead of the concrete
/// `MicrosoftOAuthClient`, so tests can inject a trivial fake refresher.
public protocol MicrosoftTokenRefreshing: Sendable {
    func refresh(refreshToken: String) async throws -> MicrosoftOAuthTokens
}
