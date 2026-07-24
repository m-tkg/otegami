import Foundation

/// Fixed OAuth2 endpoints + per-build configuration (client id, scope) for
/// Gmail's Authorization Code + PKCE flow. Kept as its own value type
/// (rather than hardcoded inside `GoogleOAuthClient`) so `GoogleOAuthClientTests`
/// can point `tokenEndpoint`/`authorizationEndpoint` at a local stub without
/// touching real Google infrastructure — only `GoogleOAuthClientTests`
/// substitutes those two URLs; production always uses `.standard(clientId:)`.
public struct GoogleOAuthEndpoints: Sendable, Equatable {
    /// `https://accounts.google.com/o/oauth2/v2/auth` (plan-specified).
    public var authorizationEndpoint: URL
    /// `https://oauth2.googleapis.com/token` (plan-specified).
    public var tokenEndpoint: URL
    /// `https://www.googleapis.com/oauth2/v3/userinfo` — used once, right
    /// after the first token exchange, to learn the signed-in account's
    /// email address. See `GoogleOAuthClient.fetchUserEmail(accessToken:)`'s
    /// doc comment for why: the plan's scope alone (`https://mail.google.com/`)
    /// carries no identity claim an `id_token` could report, and XOAUTH2
    /// needs the email *before* the first IMAP connect can even be
    /// attempted, so there's no way to discover it via IMAP either. `email`
    /// is the minimal additional scope that unlocks this endpoint without
    /// requesting `profile`/`openid` we don't otherwise need.
    public var userInfoEndpoint: URL

    public var clientId: String
    /// Space-separated OAuth2 scope string. `https://mail.google.com/` is
    /// the plan-mandated IMAP/SMTP scope; `.../auth/userinfo.email` is the
    /// deliberate addition above.
    public var scope: String
    /// `com.googleusercontent.apps.<reversed client id>:/oauth2redirect`
    /// (plan-specified) — Google's documented redirect URI convention for
    /// "iOS" OAuth client types (no client secret), which don't require
    /// pre-registering the exact redirect URI the way a web client would.
    public var redirectURI: String

    public init(
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        userInfoEndpoint: URL,
        clientId: String,
        scope: String,
        redirectURI: String
    ) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.userInfoEndpoint = userInfoEndpoint
        self.clientId = clientId
        self.scope = scope
        self.redirectURI = redirectURI
    }

    /// The real Google endpoints, for `clientId` (e.g. read from
    /// `Info.plist`'s `GOOGLE_OAUTH_CLIENT_ID`, itself sourced from
    /// `Config/Local.xcconfig` — see `docs/oauth-setup.md`).
    public static func standard(clientId: String) -> GoogleOAuthEndpoints {
        GoogleOAuthEndpoints(
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            userInfoEndpoint: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!,
            clientId: clientId,
            scope: "https://mail.google.com/ https://www.googleapis.com/auth/userinfo.email",
            redirectURI: "\(Self.redirectScheme(forClientId: clientId)):/oauth2redirect"
        )
    }

    /// `com.googleusercontent.apps.<reversed client id>` — Google's fixed
    /// convention for the custom URL scheme an "iOS" OAuth client type's
    /// redirect URI uses. A client id looks like
    /// `1234567890-abc123.apps.googleusercontent.com`; this reverses the
    /// dot-separated components (`com.googleusercontent.apps.1234567890-abc123`).
    /// `ASWebAuthenticationSession` intercepts navigation to this scheme
    /// itself (see `ASWebAuthenticationSessionRunner`'s doc comment), so —
    /// unlike a universal-link redirect — nothing needs to be registered in
    /// `Info.plist`'s `CFBundleURLTypes` for this to work.
    public static func redirectScheme(forClientId clientId: String) -> String {
        clientId.split(separator: ".").reversed().joined(separator: ".")
    }

    /// Builds the full authorization-request URL: `authorizationEndpoint`
    /// plus every query parameter the Authorization Code + PKCE flow needs
    /// (`response_type=code`, `code_challenge`/`code_challenge_method=S256`,
    /// `state` for CSRF protection, `access_type=offline` + `prompt=consent`
    /// so Google actually issues a `refresh_token` — by default a repeat
    /// consent for the same client/scope combination silently omits it).
    func authorizationURL(pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    /// The scheme `ASWebAuthenticationSession`/`AuthorizationSessionRunning`
    /// watch for — just `redirectURI`'s scheme component, extracted once
    /// here so callers don't each re-parse it.
    var callbackURLScheme: String {
        URL(string: redirectURI)?.scheme ?? Self.redirectScheme(forClientId: clientId)
    }
}
