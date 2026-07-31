import Foundation
import OAuthKit

/// Mirrors `OAuthKit.TokenStoreError` exactly — re-exported under
/// `GoogleOAuth`'s own name so existing call sites
/// (`GoogleOAuth.TokenStoreError.reauthenticationRequired`) need no changes.
public typealias TokenStoreError = OAuthKit.TokenStoreError

extension GoogleOAuthTokens: OAuthTokenRepresentable {}

/// Owns Gmail OAuth tokens for every connected account. A thin, concrete
/// wrapper around the shared `OAuthKit.TokenStore<GoogleOAuthTokens>` — the
/// actual caching/refresh-window/invalid-grant bookkeeping (byte-identical
/// to `MicrosoftOAuth.TokenStore`'s before this consolidation) lives there;
/// this type's job is only to translate `GoogleTokenRefreshing` and
/// `GoogleOAuthError.invalidGrant` into the plain closures the shared type
/// takes, and to default `refreshTokenStore` to *this provider's* Keychain
/// service string. Kept as a concrete (non-generic) actor — rather than a
/// type alias to a generic `OAuthKit.TokenStore<...>` specialization, the
/// way `ASWebAuthenticationSessionRunner` is — because this type's own
/// public `init` takes `refresher: any GoogleTokenRefreshing` (an existing,
/// narrower parameter shape than the shared type's closure-based `init`);
/// composition keeps that call-site shape unchanged for
/// `AppEnvironment`/`NotificationService`/`TokenStoreTests`.
public actor TokenStore {
    private let core: OAuthKit.TokenStore<GoogleOAuthTokens>

    /// `refreshTokenStore`'s default is this provider's own Keychain
    /// service string — unchanged from before this consolidation
    /// (`"com.mtkg.otegami.oauth-refresh-token"`). Passed explicitly here
    /// (rather than as `KeychainRefreshTokenStore`'s own default argument,
    /// which it no longer has now that the type is shared with
    /// `MicrosoftOAuth`) so Google accounts keep resolving their existing
    /// Keychain items — changing this string would force every user to
    /// re-authenticate.
    public init(
        refresher: any GoogleTokenRefreshing,
        refreshTokenStore: any RefreshTokenStoring = KeychainRefreshTokenStore(service: "com.mtkg.otegami.oauth-refresh-token"),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        core = OAuthKit.TokenStore(
            refreshTokenStore: refreshTokenStore,
            isInvalidGrant: { ($0 as? GoogleOAuthError) == .invalidGrant },
            now: now,
            refresh: { refreshToken in try await refresher.refresh(refreshToken: refreshToken) }
        )
    }

    public func storeInitialTokens(_ tokens: GoogleOAuthTokens, accountId: String) async throws {
        try await core.storeInitialTokens(tokens, accountId: accountId)
    }

    public func accessToken(for accountId: String) async throws -> String {
        try await core.accessToken(for: accountId)
    }

    public func diagnosticScope(for accountId: String) async throws -> String? {
        try await core.diagnosticScope(for: accountId)
    }

    public func clearTokens(for accountId: String) async throws {
        try await core.clearTokens(for: accountId)
    }

    public func hasStoredRefreshToken(for accountId: String) async -> Bool {
        await core.hasStoredRefreshToken(for: accountId)
    }

    public func rawRefreshToken(for accountId: String) async -> String? {
        await core.rawRefreshToken(for: accountId)
    }
}
