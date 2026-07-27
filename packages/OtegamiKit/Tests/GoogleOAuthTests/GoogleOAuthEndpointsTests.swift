import Foundation
import Testing
@testable import GoogleOAuth

@Suite("GoogleOAuthEndpoints")
struct GoogleOAuthEndpointsTests {
    @Test
    func redirectSchemeReversesTheDotSeparatedClientId() {
        let scheme = GoogleOAuthEndpoints.redirectScheme(forClientId: "1234567890-abc123.apps.googleusercontent.com")
        #expect(scheme == "com.googleusercontent.apps.1234567890-abc123")
    }

    @Test
    func standardBuildsTheRedirectURIFromTheReversedScheme() {
        let endpoints = GoogleOAuthEndpoints.standard(clientId: "999-xyz.apps.googleusercontent.com")
        #expect(endpoints.redirectURI == "com.googleusercontent.apps.999-xyz:/oauth2redirect")
        #expect(endpoints.callbackURLScheme == "com.googleusercontent.apps.999-xyz")
    }

    @Test
    func standardPointsAtThePlanSpecifiedEndpoints() {
        let endpoints = GoogleOAuthEndpoints.standard(clientId: "abc.apps.googleusercontent.com")
        #expect(endpoints.authorizationEndpoint.absoluteString == "https://accounts.google.com/o/oauth2/v2/auth")
        #expect(endpoints.tokenEndpoint.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(endpoints.scope.contains("https://mail.google.com/"))
        #expect(endpoints.scope.contains("https://www.googleapis.com/auth/contacts.other.readonly"))
    }

    @Test
    func authorizationURLIncludesEveryPKCEAndCSRFParameter() throws {
        let endpoints = GoogleOAuthEndpoints.standard(clientId: "abc.apps.googleusercontent.com")
        let pkce = PKCE(verifier: "verifier-value", challenge: "challenge-value")
        let url = endpoints.authorizationURL(pkce: pkce, state: "state-value")

        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        #expect(value("client_id") == "abc.apps.googleusercontent.com")
        #expect(value("response_type") == "code")
        #expect(value("code_challenge") == "challenge-value")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("state") == "state-value")
        #expect(value("access_type") == "offline")
        #expect(value("prompt") == "consent")
        #expect(value("redirect_uri") == endpoints.redirectURI)
    }
}
