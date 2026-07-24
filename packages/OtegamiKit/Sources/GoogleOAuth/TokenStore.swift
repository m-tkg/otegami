import Foundation

/// Errors `TokenStore.accessToken(for:)` can throw, distinct from
/// `GoogleOAuthError` (which is about the token *endpoint*'s own responses)
/// — this is `TokenStore`'s own bookkeeping layer on top.
public enum TokenStoreError: Error, Equatable, Sendable {
    /// No refresh token stored for this account — either it was never
    /// saved (bug) or `clearTokens(for:)` already ran (e.g. account
    /// deleted mid-flight). Not the same as `.reauthenticationRequired`:
    /// this is "we never had credentials to begin with", not "they went
    /// stale".
    case missingRefreshToken
    /// The refresh token was rejected (`GoogleOAuthError.invalidGrant`) —
    /// the stored refresh token has already been deleted as part of
    /// throwing this, so the account is now in the same state as
    /// `.missingRefreshToken` until a fresh `requestAuthorization()` runs.
    /// Callers (the app layer) are expected to mark the account "要再認証"
    /// and show a UI banner when they see this.
    case reauthenticationRequired
}

/// Owns Gmail OAuth tokens for every connected account: the long-lived
/// refresh token (`RefreshTokenStoring`, Keychain-backed in production)
/// plus a short-lived, in-memory-only access-token cache with expiry
/// tracking. `MailAuth.xoauth2(accessToken:)` is supplied to
/// `MailCoreIMAPSession`/`MailCoreSMTPSession` by reading `accessToken(for:)`
/// right before `connect(auth:)` — see `AppEnvironment.auth(for:)`, the
/// "auth provider" the plan calls for at the `SyncCoordinator`
/// session-construction call sites.
public actor TokenStore {
    private struct CachedAccessToken {
        var value: String
        var expiresAt: Date
    }

    /// Refresh 5 minutes before actual expiry (plan: "失効 5 分前自動リフレッシュ")
    /// so a sync/send that starts using this token has comfortable headroom
    /// to finish before the server would reject it mid-operation.
    static let refreshWindow: TimeInterval = 5 * 60

    private let refresher: any GoogleTokenRefreshing
    private let refreshTokenStore: any RefreshTokenStoring
    private let now: @Sendable () -> Date
    private var cache: [String: CachedAccessToken] = [:]

    public init(
        refresher: any GoogleTokenRefreshing,
        refreshTokenStore: any RefreshTokenStoring = KeychainRefreshTokenStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.refresher = refresher
        self.refreshTokenStore = refreshTokenStore
        self.now = now
    }

    /// Called once right after a successful `GoogleOAuthClient.requestAuthorization()`
    /// (brand-new account) — seeds both the persisted refresh token and the
    /// in-memory access-token cache so the very first sync doesn't need an
    /// extra refresh round trip.
    public func storeInitialTokens(_ tokens: GoogleOAuthTokens, accountId: String) throws {
        cache[accountId] = CachedAccessToken(value: tokens.accessToken, expiresAt: tokens.expiresAt)
        guard let refreshToken = tokens.refreshToken else {
            // Shouldn't happen for a first-time exchange with
            // `access_type=offline&prompt=consent` (see
            // `GoogleOAuthEndpoints`'s doc comment), but if Google ever
            // omits it, there's nothing to persist — the in-memory access
            // token still works until it expires, then `accessToken(for:)`
            // will throw `.missingRefreshToken`.
            return
        }
        try refreshTokenStore.write(refreshToken, accountId: accountId)
    }

    /// Returns a currently-valid access token for `accountId`, refreshing
    /// first if the cached one is missing or expiring within
    /// `refreshWindow`. Every caller that needs `MailAuth.xoauth2` goes
    /// through this rather than reading the cache directly, so "is this
    /// about to expire" is decided in exactly one place.
    public func accessToken(for accountId: String) async throws -> String {
        if let cached = cache[accountId], cached.expiresAt.timeIntervalSince(now()) > Self.refreshWindow {
            return cached.value
        }

        guard let refreshToken = try refreshTokenStore.read(accountId: accountId) else {
            throw TokenStoreError.missingRefreshToken
        }

        do {
            let tokens = try await refresher.refresh(refreshToken: refreshToken)
            cache[accountId] = CachedAccessToken(value: tokens.accessToken, expiresAt: tokens.expiresAt)
            if let rotatedRefreshToken = tokens.refreshToken {
                try refreshTokenStore.write(rotatedRefreshToken, accountId: accountId)
            }
            return tokens.accessToken
        } catch GoogleOAuthError.invalidGrant {
            // The refresh token itself is dead — wipe it so a later call
            // fails fast with `.missingRefreshToken` instead of retrying
            // the same doomed token indefinitely, and surface the
            // reauthentication-required signal distinctly (see this type's
            // doc comment).
            try? refreshTokenStore.delete(accountId: accountId)
            cache[accountId] = nil
            throw TokenStoreError.reauthenticationRequired
        }
        // Any other error (network, `.invalidTokenResponse`, ...) is left
        // to propagate as-is — transient, not a reason to wipe stored
        // credentials.
    }

    /// Account deletion (`AppEnvironment.deleteAccount`) — wipes both the
    /// in-memory cache and the persisted refresh token, mirroring
    /// `KeychainCredentialStore.deletePassword(forAccountId:)`.
    public func clearTokens(for accountId: String) throws {
        cache[accountId] = nil
        try refreshTokenStore.delete(accountId: accountId)
    }
}
