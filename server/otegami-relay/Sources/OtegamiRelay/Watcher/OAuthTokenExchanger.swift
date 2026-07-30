import AsyncHTTPClient
import Foundation
import NIOCore
import OtegamiRelayAPI

/// Errors `OAuthTokenExchanging.accessToken(provider:refreshToken:)` can
/// throw. `WatcherPool.classifyAuthFailure` maps these onto
/// `WatchSummary.ErrorKind` — `.invalidGrant` is the one case that stops
/// the watch immediately (a dead refresh token never recovers on its own),
/// every other case is treated as transient and retried with backoff, same
/// as an IMAP connection error.
enum OAuthTokenExchangeError: Error, Equatable, CustomStringConvertible {
    /// This relay has no client id configured for `provider`
    /// (`RelayConfiguration.googleOAuthClientId`/`microsoftOAuthClientId`)
    /// — an operator setup gap, not something retrying will fix, but kept
    /// non-fatal (classified the same as `.connectionError`) so a relay
    /// that serves both password and OAuth watches doesn't need every
    /// provider configured to keep working at all.
    case missingClientId(WatchAuth.Provider)
    /// The provider's token endpoint rejected the refresh token itself
    /// (`error=invalid_grant` — revoked, expired, or the user removed the
    /// app's access). The refresh token is now permanently dead; only a
    /// fresh `requestAuthorization()` in the app (re-authenticating the
    /// account) mints a new one.
    case invalidGrant
    /// A non-2xx response that isn't `invalid_grant` (rate limiting,
    /// endpoint outage, ...).
    case tokenRequestFailed(status: Int)
    /// A 2xx response that didn't parse as the expected token JSON shape.
    case invalidResponse
    /// Couldn't reach the token endpoint at all.
    case network(String)

    var description: String {
        switch self {
        case .missingClientId(let provider):
            "no OAuth client id configured for \(provider.rawValue) (RELAY_GOOGLE_CLIENT_ID/RELAY_MICROSOFT_CLIENT_ID)"
        case .invalidGrant:
            "refresh token was rejected (invalid_grant)"
        case .tokenRequestFailed(let status):
            "token endpoint returned \(status)"
        case .invalidResponse:
            "token endpoint returned a response that couldn't be decoded"
        case .network(let description):
            "network error reaching the token endpoint: \(description)"
        }
    }
}

/// Exchanges a stored OAuth refresh token for a short-lived access token,
/// right before an `.oauth` watch's IMAP `AUTHENTICATE XOAUTH2` — see
/// `MinimalIMAPClient.authenticateXOAuth2` and `WatcherPool.runWatchLoop`.
/// The access token is never persisted anywhere (`RelayStore` only ever
/// stores the refresh token, encrypted — same as an IMAP password): each
/// (re)connect calls this again, which is cheap enough since a watch only
/// reconnects on error or roughly every `idleMaxWaitSeconds`
/// (`WatcherPool`'s doc comment), not on a tight loop.
protocol OAuthTokenExchanging: Sendable {
    func accessToken(provider: WatchAuth.Provider, refreshToken: String) async throws -> String
}

/// Real implementation, hand-rolled the same way `APNsSender` hand-rolls
/// its APNs HTTP/2 call rather than pulling in a full OAuth client library
/// for a single request shape. Deliberately does **not** depend on the
/// app's `GoogleOAuth`/`MicrosoftOAuth` packages, even though their token-
/// refresh request bodies are the same shape this mirrors: those packages
/// pull in `ASWebAuthenticationSession`-based authorization-flow code that
/// only builds on Apple platforms, and this relay target has to build and
/// run on Linux (`docs/relay-deployment.md`). This type only ever
/// reimplements the "refresh a token" half, kept in sync with
/// `GoogleOAuthClient.refresh(refreshToken:)`/
/// `MicrosoftOAuthClient.refresh(refreshToken:)` by inspection (same
/// endpoint, same parameter names, same "no client secret" shape — both
/// are "installed app" OAuth client types that don't have one).
///
/// Neither provider's refresh grant needs a client secret here: Google's
/// "iOS" OAuth client type (what `docs/oauth-setup.md` has builders create)
/// has none at all, and Microsoft's "public client" app registration
/// (`docs/oauth-setup.md`'s Microsoft section — "パブリック クライアント
/// フローを許可する") is the same "no secret, PKCE instead" shape for the
/// authorization step; the *refresh* step for either only ever needs
/// `client_id`+`refresh_token`+`grant_type` (Microsoft's also repeats
/// `scope`, same as the app's own `MicrosoftOAuthClient.refresh(refreshToken:)`).
struct OAuthTokenExchanger: OAuthTokenExchanging {
    private let transport: any OAuthHTTPTransport
    private let googleClientId: String?
    private let microsoftClientId: String?

    init(transport: any OAuthHTTPTransport, googleClientId: String?, microsoftClientId: String?) {
        self.transport = transport
        self.googleClientId = googleClientId
        self.microsoftClientId = microsoftClientId
    }

    func accessToken(provider: WatchAuth.Provider, refreshToken: String) async throws -> String {
        let tokenURL: String
        var parameters: [String: String] = ["refresh_token": refreshToken, "grant_type": "refresh_token"]

        switch provider {
        case .google:
            guard let googleClientId, !googleClientId.isEmpty else {
                throw OAuthTokenExchangeError.missingClientId(.google)
            }
            tokenURL = "https://oauth2.googleapis.com/token"
            parameters["client_id"] = googleClientId
        case .microsoft:
            guard let microsoftClientId, !microsoftClientId.isEmpty else {
                throw OAuthTokenExchangeError.missingClientId(.microsoft)
            }
            tokenURL = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
            parameters["client_id"] = microsoftClientId
            // Mirrors `MicrosoftOAuthEndpoints.standard(clientId:)`'s
            // `scope` — Microsoft's refresh grant repeats the scope the
            // original authorization grant used; only the IMAP scope
            // matters to this relay (it never sends mail), but requesting
            // the same set the app itself requests keeps the token
            // endpoint's behavior identical to what the app already
            // relies on.
            parameters["scope"] = "https://outlook.office.com/IMAP.AccessAsUser.All offline_access"
        }

        let (status, body): (Int, Data)
        do {
            (status, body) = try await transport.post(url: tokenURL, formBody: Self.formEncode(parameters))
        } catch let error as OAuthTokenExchangeError {
            throw error
        } catch {
            throw OAuthTokenExchangeError.network("\(error)")
        }

        guard (200..<300).contains(status) else {
            if let errorBody = try? JSONDecoder().decode(TokenErrorResponse.self, from: body), errorBody.error == "invalid_grant" {
                throw OAuthTokenExchangeError.invalidGrant
            }
            throw OAuthTokenExchangeError.tokenRequestFailed(status: status)
        }
        guard let success = try? JSONDecoder().decode(TokenSuccessResponse.self, from: body) else {
            throw OAuthTokenExchangeError.invalidResponse
        }
        return success.accessToken
    }

    private struct TokenSuccessResponse: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    private struct TokenErrorResponse: Decodable {
        let error: String
    }

    /// `application/x-www-form-urlencoded` body encoding — mirrors
    /// `GoogleOAuthClient.formEncode(_:)`/`MicrosoftOAuthClient
    /// .formEncode(_:)` exactly (percent-encode each pair per RFC 3986's
    /// unreserved set, rather than `URLComponents`' query-string escaping,
    /// which isn't quite right for a POST body).
    static func formEncode(_ parameters: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return parameters
            .map { key, value -> String in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
}

/// The one HTTP call `OAuthTokenExchanger` needs, factored out as its own
/// narrow protocol so `OAuthTokenExchangerTests` can inject a canned
/// response instead of hitting Google/Microsoft's real token endpoints —
/// same rationale as `GoogleOAuthClient`'s injected `URLSession` on the app
/// side, just shaped around `AsyncHTTPClient` (the library this Linux
/// target already depends on for `APNsSender`) instead of `URLSession`
/// (which doesn't exist on Linux).
protocol OAuthHTTPTransport: Sendable {
    func post(url: String, formBody: String) async throws -> (status: Int, body: Data)
}

/// Production `OAuthHTTPTransport`: a single `AsyncHTTPClient` POST.
struct AsyncHTTPClientOAuthTransport: OAuthHTTPTransport {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    func post(url: String, formBody: String) async throws -> (status: Int, body: Data) {
        var request = HTTPClientRequest(url: url)
        request.method = .POST
        request.headers.add(name: "content-type", value: "application/x-www-form-urlencoded")
        request.body = .bytes(ByteBuffer(string: formBody))

        let response = try await httpClient.execute(request, timeout: .seconds(15))
        // Token responses are a small JSON object — 1MB is a generous
        // upper bound, never a real token endpoint's response size, kept
        // only so a misbehaving/compromised endpoint can't grow the
        // relay's memory unbounded (same posture as
        // `MinimalIMAPClient.maxUntaggedBytesPerCommand`).
        let bodyBuffer = try await response.body.collect(upTo: 1024 * 1024)
        return (Int(response.status.code), Data(buffer: bodyBuffer))
    }
}
