import Foundation
import OAuthKit

/// Mirrors `OAuthKit.TokenStoreError` exactly — re-exported under
/// `MicrosoftOAuth`'s own name so existing call sites
/// (`MicrosoftOAuth.TokenStoreError.reauthenticationRequired`) need no
/// changes.
public typealias TokenStoreError = OAuthKit.TokenStoreError

extension MicrosoftOAuthTokens: OAuthTokenRepresentable {}

/// Owns Microsoft OAuth tokens for every connected Outlook/Office 365
/// account. Mirrors `GoogleOAuth.TokenStore`'s own doc comment exactly: a
/// thin, concrete wrapper around the shared
/// `OAuthKit.TokenStore<MicrosoftOAuthTokens>` — the actual caching/
/// refresh-window/invalid-grant bookkeeping lives there; this type only
/// translates `MicrosoftTokenRefreshing` and `MicrosoftOAuthError.invalidGrant`
/// into the plain closures the shared type takes, and defaults
/// `refreshTokenStore` to this provider's own Keychain service string.
public actor TokenStore {
    private let core: OAuthKit.TokenStore<MicrosoftOAuthTokens>

    /// `refreshTokenStore`'s default is this provider's own Keychain
    /// service string — unchanged from before this consolidation
    /// (`"com.mtkg.otegami.oauth-refresh-token.microsoft"`, deliberately
    /// distinct from `GoogleOAuth`'s). Passed explicitly here (rather than
    /// as `KeychainRefreshTokenStore`'s own default argument, which it no
    /// longer has now that the type is shared with `GoogleOAuth`) so
    /// Microsoft accounts keep resolving their existing Keychain items and
    /// never collide with Google's — changing this string would force every
    /// user to re-authenticate.
    public init(
        refresher: any MicrosoftTokenRefreshing,
        refreshTokenStore: any RefreshTokenStoring = KeychainRefreshTokenStore(service: "com.mtkg.otegami.oauth-refresh-token.microsoft"),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        core = OAuthKit.TokenStore(
            refreshTokenStore: refreshTokenStore,
            isInvalidGrant: { ($0 as? MicrosoftOAuthError) == .invalidGrant },
            now: now,
            refresh: { refreshToken in try await refresher.refresh(refreshToken: refreshToken) }
        )
    }

    public func storeInitialTokens(_ tokens: MicrosoftOAuthTokens, accountId: String) async throws {
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
