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
        #expect(endpoints.scope.contains("https://www.googleapis.com/auth/userinfo.profile"))
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
        #expect(value("include_granted_scopes") == "true")
        #expect(value("redirect_uri") == endpoints.redirectURI)
    }

    /// Task #47 (「毎回警告が出るのがつらい」): a brand-new account
    /// (`AppEnvironment.createGmailAccount`) always uses the default
    /// `promptConsent: true`, unchanged from before this task.
    @Test
    func authorizationURLDefaultsToForcingTheConsentPrompt() throws {
        let endpoints = GoogleOAuthEndpoints.standard(clientId: "abc.apps.googleusercontent.com")
        let pkce = PKCE(verifier: "verifier-value", challenge: "challenge-value")
        let url = endpoints.authorizationURL(pkce: pkce, state: "state-value")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first(where: { $0.name == "prompt" })?.value == "consent")
    }

    /// `AppEnvironment.reauthenticateGmailAccount` passes `promptConsent: false`
    /// once it's confirmed the account's already-granted scope covers
    /// everything currently requested — this is the part that actually
    /// skips the consent screen (and the "未検証のアプリ" warning) on a
    /// routine reauth.
    @Test
    func authorizationURLOmitsThePromptParameterWhenPromptConsentIsFalse() throws {
        let endpoints = GoogleOAuthEndpoints.standard(clientId: "abc.apps.googleusercontent.com")
        let pkce = PKCE(verifier: "verifier-value", challenge: "challenge-value")
        let url = endpoints.authorizationURL(pkce: pkce, state: "state-value", promptConsent: false)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first(where: { $0.name == "prompt" }) == nil)
        // Every other parameter is unaffected by omitting `prompt`.
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        #expect(value("access_type") == "offline")
        #expect(value("include_granted_scopes") == "true")
        #expect(value("scope") == endpoints.scope)
    }

    // MARK: - isSatisfied(byGrantedScope:)

    @Test
    func isSatisfiedIsTrueWhenGrantedScopeExactlyMatchesTheRequiredScope() {
        let endpoints = GoogleOAuthEndpoints.standard(clientId: "abc.apps.googleusercontent.com")
        #expect(endpoints.isSatisfied(byGrantedScope: endpoints.scope))
    }

    /// Google isn't guaranteed to echo the requested scopes back in the
    /// same order, so this must compare as sets, not string equality.
    @Test
    func isSatisfiedIsTrueWhenGrantedScopeIsTheSameSetInADifferentOrder() {
        let endpoints = GoogleOAuthEndpoints.standard(clientId: "abc.apps.googleusercontent.com")
        let reordered = endpoints.scope.split(separator: " ").reversed().joined(separator: " ")
        #expect(endpoints.isSatisfied(byGrantedScope: reordered))
    }

    @Test
    func isSatisfiedIsTrueWhenGrantedScopeIsASupersetOfTheRequiredScope() {
        let endpoints = GoogleOAuthEndpoints.standard(clientId: "abc.apps.googleusercontent.com")
        let superset = endpoints.scope + " https://www.googleapis.com/auth/some.extra.scope"
        #expect(endpoints.isSatisfied(byGrantedScope: superset))
    }

    @Test
    func isSatisfiedIsFalseWhenGrantedScopeIsMissingARequiredScope() {
        let endpoints = GoogleOAuthEndpoints.standard(clientId: "abc.apps.googleusercontent.com")
        let missingContacts = "https://mail.google.com/ https://www.googleapis.com/auth/userinfo.email"
        #expect(!endpoints.isSatisfied(byGrantedScope: missingContacts))
    }

    /// `nil` (no cached grant, or `TokenStore.diagnosticScope(for:)` itself
    /// failed) must fall back to "not satisfied" — the safe default is to
    /// force the consent screen when this genuinely can't be determined.
    @Test
    func isSatisfiedIsFalseWhenGrantedScopeIsNil() {
        let endpoints = GoogleOAuthEndpoints.standard(clientId: "abc.apps.googleusercontent.com")
        #expect(!endpoints.isSatisfied(byGrantedScope: nil))
    }
}
