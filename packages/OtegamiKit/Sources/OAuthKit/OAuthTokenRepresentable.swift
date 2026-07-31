import Foundation

/// What `TokenStore` needs from a provider's token-exchange result
/// (`GoogleOAuthTokens`/`MicrosoftOAuthTokens`) to do its caching/refresh
/// bookkeeping, without needing to know about anything provider-specific
/// (e.g. Microsoft's `idToken`). Both existing token types already have
/// exactly these four stored properties, so conforming them needs no extra
/// code beyond the conformance declaration itself
/// (`extension GoogleOAuthTokens: OAuthTokenRepresentable {}`).
public protocol OAuthTokenRepresentable: Sendable, Equatable {
    var accessToken: String { get }
    /// `nil` on a *refresh* response — the provider only returns a new
    /// refresh token on rotation; `TokenStore` keeps the previous one in
    /// that case. Always present on the first exchange.
    var refreshToken: String? { get }
    var expiresAt: Date { get }
    var scope: String? { get }
}
