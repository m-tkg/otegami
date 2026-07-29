import Foundation
import Testing
@testable import MicrosoftOAuth

@Suite("MicrosoftOAuthEndpoints")
struct MicrosoftOAuthEndpointsTests {
    @Test
    func standardPointsAtThePlanSpecifiedEndpoints() {
        let endpoints = MicrosoftOAuthEndpoints.standard(clientId: "test-client-id")
        #expect(endpoints.authorizationEndpoint.absoluteString == "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")
        #expect(endpoints.tokenEndpoint.absoluteString == "https://login.microsoftonline.com/common/oauth2/v2.0/token")
        #expect(endpoints.scope == "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access openid email")
        #expect(endpoints.redirectURI == MicrosoftOAuthEndpoints.standardRedirectURI)
    }

    @Test
    func authorizationURLIncludesEveryPKCEAndCSRFParameter() throws {
        let endpoints = MicrosoftOAuthEndpoints.standard(clientId: "test-client-id")
        let pkce = PKCE(verifier: "verifier-value", challenge: "challenge-value")
        let url = endpoints.authorizationURL(pkce: pkce, state: "state-value")

        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        #expect(value("client_id") == "test-client-id")
        #expect(value("response_type") == "code")
        #expect(value("response_mode") == "query")
        #expect(value("code_challenge") == "challenge-value")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("state") == "state-value")
        #expect(value("prompt") == "select_account")
        #expect(value("scope") == endpoints.scope)
        #expect(value("redirect_uri") == endpoints.redirectURI)
    }

    @Test
    func callbackURLSchemeMatchesTheRedirectURIsScheme() {
        let endpoints = MicrosoftOAuthEndpoints.standard(clientId: "test-client-id")
        #expect(endpoints.callbackURLScheme == "com.mtkg.otegami.msauth")
        #expect(endpoints.redirectURI == "com.mtkg.otegami.msauth://oauth2redirect")
    }

    /// Outlook.com and Office365 (`AccountTypeSelectionView`'s two separate
    /// buttons) both resolve to the exact same endpoints — the `common`
    /// tenant covers personal and work/school accounts alike, so there's no
    /// server-side distinction between the two entry points.
    @Test
    func standardIsIdenticalRegardlessOfWhichButtonTriggeredIt() {
        let outlook = MicrosoftOAuthEndpoints.standard(clientId: "shared-client-id")
        let office365 = MicrosoftOAuthEndpoints.standard(clientId: "shared-client-id")
        #expect(outlook == office365)
    }
}
