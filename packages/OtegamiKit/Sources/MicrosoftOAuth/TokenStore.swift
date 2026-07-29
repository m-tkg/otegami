import Foundation

/// Mirrors `GoogleOAuth.TokenStoreError`.
public enum TokenStoreError: Error, Equatable, Sendable {
    case missingRefreshToken
    case reauthenticationRequired
}

/// Owns Microsoft OAuth tokens for every connected Outlook/Office 365
/// account — mirrors `GoogleOAuth.TokenStore` exactly (same refresh-window,
/// same cache-then-refresh-then-cache shape, same `invalid_grant` →
/// `.reauthenticationRequired` mapping). Kept as its own type (rather than
/// making `GoogleOAuth.TokenStore` generic over a `TokenRefreshing`
/// protocol and a token type) to keep `MicrosoftOAuth` fully independent of
/// `GoogleOAuth` — see this package's `Package.swift` comment on the
/// `MicrosoftOAuth` target.
public actor TokenStore {
    private struct CachedAccessToken {
        var value: String
        var expiresAt: Date
    }

    static let refreshWindow: TimeInterval = 5 * 60

    private let refresher: any MicrosoftTokenRefreshing
    private let refreshTokenStore: any RefreshTokenStoring
    private let now: @Sendable () -> Date
    private var cache: [String: CachedAccessToken] = [:]

    public init(
        refresher: any MicrosoftTokenRefreshing,
        refreshTokenStore: any RefreshTokenStoring = KeychainRefreshTokenStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.refresher = refresher
        self.refreshTokenStore = refreshTokenStore
        self.now = now
    }

    public func storeInitialTokens(_ tokens: MicrosoftOAuthTokens, accountId: String) throws {
        cache[accountId] = CachedAccessToken(value: tokens.accessToken, expiresAt: tokens.expiresAt)
        guard let refreshToken = tokens.refreshToken else { return }
        try refreshTokenStore.write(refreshToken, accountId: accountId)
    }

    public func accessToken(for accountId: String) async throws -> String {
        if let cached = cache[accountId], cached.expiresAt.timeIntervalSince(now()) > Self.refreshWindow {
            return cached.value
        }
        let tokens = try await refreshAndCache(accountId: accountId)
        return tokens.accessToken
    }

    /// Diagnostic-only counterpart to `accessToken(for:)` — mirrors
    /// `GoogleOAuth.TokenStore.diagnosticScope(for:)`. Not currently wired
    /// into any UI (`AccountEditView`'s "権限の診断" display is Gmail-only
    /// today), kept for parity/future use since it costs nothing extra to
    /// mirror.
    public func diagnosticScope(for accountId: String) async throws -> String? {
        let tokens = try await refreshAndCache(accountId: accountId)
        return tokens.scope
    }

    private func refreshAndCache(accountId: String) async throws -> MicrosoftOAuthTokens {
        guard let refreshToken = try refreshTokenStore.read(accountId: accountId) else {
            throw TokenStoreError.missingRefreshToken
        }

        do {
            let tokens = try await refresher.refresh(refreshToken: refreshToken)
            cache[accountId] = CachedAccessToken(value: tokens.accessToken, expiresAt: tokens.expiresAt)
            if let rotatedRefreshToken = tokens.refreshToken {
                try refreshTokenStore.write(rotatedRefreshToken, accountId: accountId)
            }
            return tokens
        } catch MicrosoftOAuthError.invalidGrant {
            try? refreshTokenStore.delete(accountId: accountId)
            cache[accountId] = nil
            throw TokenStoreError.reauthenticationRequired
        }
    }

    public func clearTokens(for accountId: String) throws {
        cache[accountId] = nil
        try refreshTokenStore.delete(accountId: accountId)
    }

    /// Mirrors `GoogleOAuth.TokenStore.hasStoredRefreshToken(for:)` — used
    /// by `AccountCloudSync.LocalAccountDirectory.hasCredential` for a
    /// cloud-discovered `.microsoft`-kind account, same rationale as
    /// Google's.
    public func hasStoredRefreshToken(for accountId: String) -> Bool {
        (try? refreshTokenStore.read(accountId: accountId))?.isEmptyOrNil == false
    }
}

private extension Optional where Wrapped == String {
    var isEmptyOrNil: Bool {
        switch self {
        case .none: return true
        case .some(let value): return value.isEmpty
        }
    }
}
