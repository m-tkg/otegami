import Foundation
import OAuthKit

/// Mirrors `GoogleOAuth.GoogleOAuthError` — see that type's doc comment for
/// the overall rationale (one flat enum since every call site needs the
/// same small set of UI decisions), including why this conforms to
/// `OAuthKit.OAuthFlowError`.
public enum MicrosoftOAuthError: Error, Equatable, Sendable, OAuthFlowError {
    case userCancelled
    case stateMismatch
    case missingAuthorizationCode
    case authorizationDenied(reason: String)
    case invalidTokenResponse
    /// The token endpoint's `error` field was specifically `invalid_grant`
    /// on a *refresh* request — mirrors `GoogleOAuthError.invalidGrant`'s
    /// "refresh token is dead, need a brand new sign-in" signal. Azure AD
    /// v2.0 reports this the same way Google does (RFC 6749 §5.2 `error`
    /// field), so no extra Microsoft-specific error code mapping was
    /// needed here.
    case invalidGrant
    case tokenRequestFailed(error: String, description: String?)
    /// The id_token's claims had no usable `email`/`preferred_username`
    /// (see `MicrosoftOAuthClient.fetchUserEmail(idToken:)`'s doc comment
    /// for why this is decoded from the id_token rather than a separate
    /// Graph API call).
    case missingEmail
    case network(underlyingDescription: String)
}
