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
        let tokens = try await refreshAndCache(accountId: accountId)
        return tokens.accessToken
    }

    /// Diagnostic-only counterpart to `accessToken(for:)`, for
    /// `AccountEditView`'s "権限の診断" display — the real-device bug this
    /// exists to help debug is Google silently not granting a newly-added
    /// scope on reauth, and `accessToken(for:)` alone can't answer "what
    /// scope did Google actually grant this token" because a cache hit
    /// (the common case — most calls happen well before the 5-minute
    /// refresh window) never touches the token endpoint at all, so there's
    /// no `scope` field to read. This always forces a real refresh — never
    /// serves the cache — so its answer is never stale by more than the
    /// time this call itself takes. Not on the hot path (`auth(for:)`
    /// doesn't call this), so the extra network round trip only happens
    /// when a user explicitly opens the diagnostic. Same
    /// `.invalidGrant`/`TokenStoreError.reauthenticationRequired` handling
    /// as `accessToken(for:)` — a dead refresh token is just as dead here.
    public func diagnosticScope(for accountId: String) async throws -> String? {
        let tokens = try await refreshAndCache(accountId: accountId)
        return tokens.scope
    }

    private func refreshAndCache(accountId: String) async throws -> GoogleOAuthTokens {
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

    /// M11 (iCloud account sync): whether a refresh token is currently
    /// stored for `accountId`, without attempting to use or refresh it.
    /// `AccountCloudSync.LocalAccountDirectory.hasCredential` uses this for
    /// a cloud-discovered `.gmail`-kind account — deliberately doesn't go
    /// through `accessToken(for:)` (which would try a network refresh and
    /// throw on failure) since all this needs to answer is "does *some*
    /// credential already exist on this device to start syncing with",
    /// not "is it still valid".
    public func hasStoredRefreshToken(for accountId: String) -> Bool {
        (try? refreshTokenStore.read(accountId: accountId))?.isEmptyOrNil == false
    }

    /// Task #175 (push relay OAuth watches): the raw, still-valid refresh
    /// token itself — unlike `accessToken(for:)`, this never talks to
    /// Google, and unlike `hasStoredRefreshToken(for:)`, it returns the
    /// value rather than just whether one exists. `AppEnvironment
    /// .watchAuth(for:)` uses this to hand the relay a refresh token when
    /// registering a Gmail account's push watch — the relay needs its own
    /// copy to exchange for access tokens on every (re)connect (see
    /// `server/otegami-relay`'s `OAuthTokenExchanger`), the same way it
    /// already needs a `.password` account's IMAP password. `nil` if
    /// nothing is stored (mirrors `hasStoredRefreshToken(for:)`'s
    /// `false` case).
    public func rawRefreshToken(for accountId: String) -> String? {
        guard let token = try? refreshTokenStore.read(accountId: accountId), !token.isEmpty else { return nil }
        return token
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
