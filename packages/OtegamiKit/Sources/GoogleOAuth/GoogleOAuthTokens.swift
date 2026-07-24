import Foundation

/// Result of a token exchange or refresh — the normalized, `Sendable` form
/// `GoogleOAuthClient` returns to callers (`TokenStore`, `GoogleOAuthClientTests`).
/// `expiresAt` is an absolute `Date` (computed from the response's relative
/// `expires_in` seconds against an injectable clock) rather than a raw
/// interval, so `TokenStore`'s "expiring within 5 minutes" check never needs
/// to remember when the response arrived.
public struct GoogleOAuthTokens: Sendable, Equatable {
    public var accessToken: String
    /// `nil` on a *refresh* response — Google only returns a new
    /// `refresh_token` on rare rotation; `TokenStore` keeps the previous one
    /// in that case. Always present on the first exchange (with
    /// `access_type=offline&prompt=consent`, per `GoogleOAuthEndpoints`'s
    /// doc comment).
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }
}

/// The token endpoint's raw JSON success shape (RFC 6749 §5.1). Decoded
/// straight from the HTTP body; `GoogleOAuthClient` converts it to
/// `GoogleOAuthTokens` (resolving `expires_in` against `now()`) immediately
/// after.
struct GoogleTokenSuccessResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let scope: String?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }
}

/// The token endpoint's raw JSON error shape (RFC 6749 §5.2), e.g.
/// `{"error":"invalid_grant","error_description":"Token has been expired or revoked."}`.
/// `error == "invalid_grant"` on a *refresh* call is exactly the plan's
/// "リフレッシュ失敗 (invalid_grant) → アカウントを「要再認証」状態に" trigger —
/// `GoogleOAuthClient` maps it to `GoogleOAuthError.invalidGrant` specifically
/// so `TokenStore` can distinguish "needs a fresh sign-in" from a merely
/// transient network/server failure.
struct GoogleTokenErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

struct GoogleUserInfoResponse: Decodable {
    let email: String?
}
