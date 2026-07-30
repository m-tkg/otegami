import Foundation
import Testing

@testable import OtegamiRelay

/// `OAuthTokenExchanger`'s own HTTP-parsing logic, against a scripted
/// `OAuthHTTPTransport` — never touches Google/Microsoft's real token
/// endpoints (task requirement: "実 Google を叩かない"). `WatcherPoolTests`
/// separately covers the end-to-end "watch stops on invalid_grant" behavior
/// using `FakeOAuthTokenExchanger` (a fake of the whole
/// `OAuthTokenExchanging` protocol, one layer up) — this file is the
/// narrower unit test of the request/response shape itself.
@Suite("OAuthTokenExchanger")
struct OAuthTokenExchangerTests {
    @Test("Google: successful refresh returns the access token, using client_id with no client_secret")
    func googleSuccessfulRefresh() async throws {
        let transport = ScriptedOAuthHTTPTransport { url, formBody in
            #expect(url == "https://oauth2.googleapis.com/token")
            #expect(formBody.contains("client_id=test-google-client-id"))
            #expect(formBody.contains("refresh_token=stored-refresh-token"))
            #expect(formBody.contains("grant_type=refresh_token"))
            #expect(!formBody.contains("client_secret"))
            return (200, Data(#"{"access_token":"fresh-google-token","expires_in":3600}"#.utf8))
        }
        let exchanger = OAuthTokenExchanger(transport: transport, googleClientId: "test-google-client-id", microsoftClientId: nil)
        let accessToken = try await exchanger.accessToken(provider: .google, refreshToken: "stored-refresh-token")
        #expect(accessToken == "fresh-google-token")
    }

    @Test("Microsoft: successful refresh returns the access token, repeating the IMAP scope")
    func microsoftSuccessfulRefresh() async throws {
        let transport = ScriptedOAuthHTTPTransport { url, formBody in
            #expect(url == "https://login.microsoftonline.com/common/oauth2/v2.0/token")
            #expect(formBody.contains("client_id=test-ms-client-id"))
            #expect(formBody.contains("refresh_token=stored-refresh-token"))
            #expect(formBody.contains("scope="))
            #expect(!formBody.contains("client_secret"))
            return (200, Data(#"{"access_token":"fresh-ms-token","expires_in":3600}"#.utf8))
        }
        let exchanger = OAuthTokenExchanger(transport: transport, googleClientId: nil, microsoftClientId: "test-ms-client-id")
        let accessToken = try await exchanger.accessToken(provider: .microsoft, refreshToken: "stored-refresh-token")
        #expect(accessToken == "fresh-ms-token")
    }

    @Test("no client id configured for the provider throws .missingClientId without making an HTTP call")
    func missingClientIdNeverCallsTransport() async throws {
        let transport = ScriptedOAuthHTTPTransport { _, _ in
            Issue.record("transport should never be called when no client id is configured")
            return (200, Data())
        }
        let exchanger = OAuthTokenExchanger(transport: transport, googleClientId: nil, microsoftClientId: nil)
        await #expect(throws: OAuthTokenExchangeError.missingClientId(.google)) {
            _ = try await exchanger.accessToken(provider: .google, refreshToken: "whatever")
        }
    }

    @Test("invalid_grant response throws .invalidGrant")
    func invalidGrantResponse() async throws {
        let transport = ScriptedOAuthHTTPTransport { _, _ in
            (400, Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8))
        }
        let exchanger = OAuthTokenExchanger(transport: transport, googleClientId: "cid", microsoftClientId: nil)
        await #expect(throws: OAuthTokenExchangeError.invalidGrant) {
            _ = try await exchanger.accessToken(provider: .google, refreshToken: "dead-token")
        }
    }

    @Test("a non-invalid_grant error response throws .tokenRequestFailed with the status code")
    func otherErrorResponse() async throws {
        let transport = ScriptedOAuthHTTPTransport { _, _ in
            (429, Data(#"{"error":"rate_limited"}"#.utf8))
        }
        let exchanger = OAuthTokenExchanger(transport: transport, googleClientId: "cid", microsoftClientId: nil)
        await #expect(throws: OAuthTokenExchangeError.tokenRequestFailed(status: 429)) {
            _ = try await exchanger.accessToken(provider: .google, refreshToken: "token")
        }
    }

    @Test("a 2xx response that doesn't parse as the expected JSON shape throws .invalidResponse")
    func unparseableSuccessResponse() async throws {
        let transport = ScriptedOAuthHTTPTransport { _, _ in
            (200, Data("not json".utf8))
        }
        let exchanger = OAuthTokenExchanger(transport: transport, googleClientId: "cid", microsoftClientId: nil)
        await #expect(throws: OAuthTokenExchangeError.invalidResponse) {
            _ = try await exchanger.accessToken(provider: .google, refreshToken: "token")
        }
    }

    @Test("a transport-level failure throws .network")
    func transportFailureThrowsNetwork() async throws {
        struct ThrowawayError: Error {}
        let transport = ScriptedOAuthHTTPTransport { _, _ in
            throw ThrowawayError()
        }
        let exchanger = OAuthTokenExchanger(transport: transport, googleClientId: "cid", microsoftClientId: nil)
        do {
            _ = try await exchanger.accessToken(provider: .google, refreshToken: "token")
            Issue.record("expected a .network error")
        } catch OAuthTokenExchangeError.network {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

/// A scripted `OAuthHTTPTransport` — every test above supplies its own
/// `handler` closure instead of a shared stateful fake, since each test
/// only ever makes (at most) one call.
private struct ScriptedOAuthHTTPTransport: OAuthHTTPTransport {
    let handler: @Sendable (String, String) throws -> (Int, Data)

    func post(url: String, formBody: String) async throws -> (status: Int, body: Data) {
        let (status, body) = try handler(url, formBody)
        return (status, body)
    }
}
