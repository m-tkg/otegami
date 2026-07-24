import Foundation

/// Errors surfaced by `GoogleOAuthClient`/`TokenStore`. Kept as one flat
/// enum (rather than per-type errors) since every call site that catches
/// one of these needs to make the same small set of UI decisions
/// (transient failure vs. "sign in again").
public enum GoogleOAuthError: Error, Equatable, Sendable {
    /// The user dismissed/cancelled the `ASWebAuthenticationSession` sheet.
    /// Not a failure worth surfacing as an error banner — the caller should
    /// just return to the account-type picker.
    case userCancelled
    /// The authorization callback's `state` query parameter didn't match
    /// the one this flow generated — a forged/replayed redirect. Treated
    /// the same as a hard failure (never silently proceeds).
    case stateMismatch
    /// The callback URL had no `code` parameter at all (and no `error`
    /// either) — malformed redirect.
    case missingAuthorizationCode
    /// The callback URL carried an OAuth `error` parameter (e.g.
    /// `access_denied` if the user declined the consent screen).
    case authorizationDenied(reason: String)
    /// The token endpoint responded with a non-2xx status and a body that
    /// didn't even parse as `GoogleTokenErrorResponse`.
    case invalidTokenResponse
    /// The token endpoint's `error` field was specifically `invalid_grant`
    /// on a *refresh* request — the refresh token is dead (revoked,
    /// expired, or the user changed their Google password) and the account
    /// needs a brand new `requestAuthorization()` flow. See `TokenStore`'s
    /// doc comment for how this becomes an account's "要再認証" state.
    case invalidGrant
    /// Any other `error` the token endpoint reported (e.g.
    /// `invalid_client`, `unauthorized_client` — typically a misconfigured
    /// `GOOGLE_OAUTH_CLIENT_ID`, not something a re-auth fixes).
    case tokenRequestFailed(error: String, description: String?)
    /// The userinfo endpoint's response had no usable `email` field.
    case missingEmail
    /// A transport-level failure (no connectivity, DNS, TLS, ...) wrapped
    /// from `URLSession`.
    case network(underlyingDescription: String)
}
