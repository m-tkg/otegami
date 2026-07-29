import Foundation

/// Result of a token exchange or refresh — mirrors `GoogleOAuth
/// .GoogleOAuthTokens`. Carries `idToken` (which Google's counterpart
/// doesn't need to) because `MicrosoftOAuthClient.fetchUserEmail(idToken:)`
/// reads the signed-in account's email straight out of it — see that
/// method's doc comment.
public struct MicrosoftOAuthTokens: Sendable, Equatable {
    public var accessToken: String
    /// `nil` on a refresh response that didn't rotate it — same "keep the
    /// previous one" handling as `GoogleOAuthTokens.refreshToken`.
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?
    /// Present on the *first* exchange (the `openid` scope requests it);
    /// Azure AD v2.0 also returns a (usually identical-claims) id_token on
    /// a refresh response as long as `openid` remains in scope, but nothing
    /// here depends on that — the email is only ever read once, right after
    /// the initial interactive sign-in.
    public var idToken: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String? = nil, idToken: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.idToken = idToken
    }
}

/// The token endpoint's raw JSON success shape (RFC 6749 §5.1, same shape
/// Azure AD v2.0 and Google both use).
struct MicrosoftTokenSuccessResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let scope: String?
    let tokenType: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
        case idToken = "id_token"
    }
}

/// The token endpoint's raw JSON error shape (RFC 6749 §5.2) — identical
/// shape to Google's, Azure AD v2.0 follows the same spec here.
struct MicrosoftTokenErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// The claims this app actually reads out of an id_token's JWT payload.
/// **Deliberately does not verify the JWT signature** — the id_token is
/// read straight from Azure AD's own token endpoint response over TLS
/// (never handed to this app by any other party, unlike e.g. a JWT
/// forwarded through an untrusted redirect), so there's no attacker who
/// could hand this code a forged token to parse in the first place; the
/// only thing this ever does with the decoded claims is read a display
/// value (email), never an authorization decision. Verifying the signature
/// would need Microsoft's JWKS endpoint plus a JWT library this package
/// doesn't otherwise need — deliberately skipped as scope this task doesn't
/// require. See `MicrosoftOAuthClient.fetchUserEmail(idToken:)`.
struct MicrosoftIDTokenClaims: Decodable {
    let email: String?
    let preferredUsername: String?

    enum CodingKeys: String, CodingKey {
        case email
        case preferredUsername = "preferred_username"
    }

    /// Decodes the middle (payload) segment of a `header.payload.signature`
    /// JWT. Returns `nil` for anything that doesn't even parse as a 3-part
    /// base64url JWT — callers treat that the same as "no claims".
    static func decode(_ idToken: String) -> MicrosoftIDTokenClaims? {
        let segments = idToken.split(separator: ".")
        guard segments.count == 3 else { return nil }
        guard let payloadData = base64URLDecode(String(segments[1])) else { return nil }
        return try? JSONDecoder().decode(MicrosoftIDTokenClaims.self, from: payloadData)
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
