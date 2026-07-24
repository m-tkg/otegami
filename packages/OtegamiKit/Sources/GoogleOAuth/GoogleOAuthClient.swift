import Foundation

/// Orchestrates Gmail's Authorization Code + PKCE (S256) flow end to end:
/// build the authorization URL → run it through an injected
/// `AuthorizationSessionRunning` → parse the callback → exchange the code
/// for tokens. Also the one place that knows how to refresh a token and how
/// to look up the signed-in account's email (`TokenStore`/the app call
/// these directly, independent of a full `requestAuthorization()` run).
///
/// `URLSession` is injected (default `.shared`) rather than hardcoded so
/// `GoogleOAuthClientTests` can point every HTTP call at a `URLProtocol`
/// stub instead of real Google servers (plan: "ローカル HTTP スタブ
/// (URLProtocol モック)").
public actor GoogleOAuthClient: GoogleTokenRefreshing {
    private let endpoints: GoogleOAuthEndpoints
    private let urlSession: URLSession
    private let sessionRunner: any AuthorizationSessionRunning
    private let pkceGenerator: @Sendable () -> PKCE
    private let stateGenerator: @Sendable () -> String
    private let now: @Sendable () -> Date

    public init(
        endpoints: GoogleOAuthEndpoints,
        sessionRunner: any AuthorizationSessionRunning,
        urlSession: URLSession = .shared,
        pkceGenerator: @escaping @Sendable () -> PKCE = { PKCE.generate() },
        stateGenerator: @escaping @Sendable () -> String = { GoogleOAuthClient.randomState() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.endpoints = endpoints
        self.urlSession = urlSession
        self.sessionRunner = sessionRunner
        self.pkceGenerator = pkceGenerator
        self.stateGenerator = stateGenerator
        self.now = now
    }

    /// Runs the full interactive flow: presents the consent screen, waits
    /// for the redirect, and exchanges the resulting code for tokens.
    /// Throws `GoogleOAuthError.userCancelled` if the user dismisses the
    /// sheet, `.stateMismatch`/`.missingAuthorizationCode`/`.authorizationDenied`
    /// for a malformed or rejected callback, or a token-exchange error (see
    /// `exchangeCode(_:verifier:)`).
    public func requestAuthorization() async throws -> GoogleOAuthTokens {
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

    /// Exchanges an authorization `code` (plus its matching PKCE `verifier`)
    /// for an access/refresh token pair. Exposed separately from
    /// `requestAuthorization()` so `GoogleOAuthClientTests` can drive this
    /// half in isolation from the `AuthorizationSessionRunning` mock.
    public func exchangeCode(_ code: String, verifier: String) async throws -> GoogleOAuthTokens {
        var parameters: [String: String] = [
            "client_id": endpoints.clientId,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": endpoints.redirectURI,
        ]
        return try await requestTokens(parameters: &parameters, isRefresh: false)
    }

    /// Exchanges a stored `refreshToken` for a fresh access token. Throws
    /// `GoogleOAuthError.invalidGrant` specifically when Google reports the
    /// refresh token itself is dead — `TokenStore` relies on being able to
    /// distinguish that from every other failure mode.
    public func refresh(refreshToken: String) async throws -> GoogleOAuthTokens {
        var parameters: [String: String] = [
            "client_id": endpoints.clientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        return try await requestTokens(parameters: &parameters, isRefresh: true)
    }

    /// Looks up the signed-in account's email via the userinfo endpoint —
    /// see `GoogleOAuthEndpoints.userInfoEndpoint`'s doc comment for why
    /// this round trip exists at all (XOAUTH2 needs the email *before* the
    /// first IMAP connect, and the plan's minimal scope carries no identity
    /// claim otherwise).
    public func fetchUserEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: endpoints.userInfoEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GoogleOAuthError.invalidTokenResponse
        }
        guard let decoded = try? JSONDecoder().decode(GoogleUserInfoResponse.self, from: data),
              let email = decoded.email, !email.isEmpty
        else {
            throw GoogleOAuthError.missingEmail
        }
        return email
    }

    // MARK: - Token endpoint

    private func requestTokens(parameters: inout [String: String], isRefresh: Bool) async throws -> GoogleOAuthTokens {
        var request = URLRequest(url: endpoints.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(parameters)

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleOAuthError.invalidTokenResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            if let errorBody = try? JSONDecoder().decode(GoogleTokenErrorResponse.self, from: data) {
                if isRefresh, errorBody.error == "invalid_grant" {
                    throw GoogleOAuthError.invalidGrant
                }
                throw GoogleOAuthError.tokenRequestFailed(error: errorBody.error, description: errorBody.errorDescription)
            }
            throw GoogleOAuthError.invalidTokenResponse
        }

        let decoder = JSONDecoder()
        guard let success = try? decoder.decode(GoogleTokenSuccessResponse.self, from: data) else {
            throw GoogleOAuthError.invalidTokenResponse
        }
        return GoogleOAuthTokens(
            accessToken: success.accessToken,
            refreshToken: success.refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(success.expiresIn)),
            scope: success.scope
        )
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await urlSession.data(for: request)
        } catch let error as GoogleOAuthError {
            throw error
        } catch {
            throw GoogleOAuthError.network(underlyingDescription: "\(error)")
        }
    }

    // MARK: - Callback parsing

    static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        if let error = value("error") {
            throw GoogleOAuthError.authorizationDenied(reason: error)
        }
        guard value("state") == expectedState else {
            throw GoogleOAuthError.stateMismatch
        }
        guard let code = value("code"), !code.isEmpty else {
            throw GoogleOAuthError.missingAuthorizationCode
        }
        return code
    }

    public static func randomState() -> String {
        PKCE.base64URLEncode(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
    }

    /// `application/x-www-form-urlencoded` body encoding — `URLComponents`
    /// percent-encoding (used for the authorization *URL*'s query string)
    /// isn't quite the right escaping for a POST body's `+`-for-space
    /// convention, so this encodes each pair directly per RFC 3986's
    /// unreserved set (letters/digits/`-._~`), matching what the token
    /// endpoint expects.
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

/// Narrow protocol `TokenStore` depends on instead of the concrete
/// `GoogleOAuthClient` — lets `TokenStoreTests` inject a trivial fake
/// refresher (canned success/`invalid_grant`/network-failure responses)
/// without spinning up PKCE/`AuthorizationSessionRunning` machinery that
/// refreshing never actually touches.
public protocol GoogleTokenRefreshing: Sendable {
    func refresh(refreshToken: String) async throws -> GoogleOAuthTokens
}
