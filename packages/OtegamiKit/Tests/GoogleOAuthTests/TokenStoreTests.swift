import Foundation
import OAuthKitTestSupport
import Testing
@testable import GoogleOAuth

@Suite("TokenStore")
struct TokenStoreTests {
    private let accountId = "account-1"
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func storeInitialTokensCachesTheAccessTokenAndPersistsTheRefreshToken() async throws {
        let refresher = FakeTokenRefresher { _ in fatalError("refresh should not be called") }
        let keychain = FakeRefreshTokenStore()
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        try await store.storeInitialTokens(
            GoogleOAuthTokens(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: epoch.addingTimeInterval(3600)),
            accountId: accountId
        )

        #expect(try await store.accessToken(for: accountId) == "access-1")
        #expect(refresher.refreshCallCount == 0)
        #expect(keychain.currentValue(accountId: accountId) == "refresh-1")
    }

    /// Task #47 (「毎回警告が出るのがつらい」): a `reauthenticateGmailAccount`
    /// run with `promptConsent: false` (the account's granted scope already
    /// covered everything requested) can get back a token response with no
    /// `refresh_token` at all — Google's documented behavior for a
    /// prompt-less repeat grant. This must not wipe the refresh token this
    /// account already had stored from a previous, full authorization —
    /// only a response that *does* include one should ever overwrite the
    /// stored value (see the sibling
    /// `accessTokenPersistsARotatedRefreshTokenWhenGoogleReturnsOne` test
    /// for the "does" half of that, in `refreshAndCache`).
    @Test
    func storeInitialTokensPreservesTheExistingRefreshTokenWhenTheResponseOmitsOne() async throws {
        let refresher = FakeTokenRefresher { _ in fatalError("refresh should not be called") }
        let keychain = FakeRefreshTokenStore()
        keychain.seed("original-refresh", accountId: accountId)
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        try await store.storeInitialTokens(
            GoogleOAuthTokens(accessToken: "access-from-silent-reauth", refreshToken: nil, expiresAt: epoch.addingTimeInterval(3600)),
            accountId: accountId
        )

        #expect(try await store.accessToken(for: accountId) == "access-from-silent-reauth")
        #expect(keychain.currentValue(accountId: accountId) == "original-refresh")
        // The absence of a refresh token in the response must not even
        // trigger a Keychain write — `write(_:accountId:)` is skipped
        // entirely, not called with the old value re-supplied.
        #expect(keychain.writeCount == 0)
    }

    @Test
    func accessTokenRefreshesWhenNoTokenIsCachedYet() async throws {
        let refresher = FakeTokenRefresher { refreshToken in
            #expect(refreshToken == "stored-refresh")
            return GoogleOAuthTokens(accessToken: "fresh-access", refreshToken: nil, expiresAt: self.epoch.addingTimeInterval(3600))
        }
        let keychain = FakeRefreshTokenStore()
        keychain.seed("stored-refresh", accountId: accountId)
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        let token = try await store.accessToken(for: accountId)
        #expect(token == "fresh-access")
        #expect(refresher.refreshCallCount == 1)
    }

    @Test
    func accessTokenDoesNotRefreshWhenComfortablyValid() async throws {
        let refresher = FakeTokenRefresher { _ in fatalError("should not refresh a token valid for 30 more minutes") }
        let keychain = FakeRefreshTokenStore()
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        try await store.storeInitialTokens(
            GoogleOAuthTokens(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: epoch.addingTimeInterval(30 * 60)),
            accountId: accountId
        )

        #expect(try await store.accessToken(for: accountId) == "access-1")
    }

    /// Plan: "失効 5 分前自動リフレッシュ" — a token expiring in exactly 4
    /// minutes is inside the refresh window and must trigger a refresh
    /// before being handed out, even though it hasn't technically expired
    /// yet.
    @Test
    func accessTokenRefreshesWhenWithinFiveMinutesOfExpiry() async throws {
        let refresher = FakeTokenRefresher { _ in
            GoogleOAuthTokens(accessToken: "refreshed-access", refreshToken: nil, expiresAt: self.epoch.addingTimeInterval(3600))
        }
        let keychain = FakeRefreshTokenStore()
        keychain.seed("stored-refresh", accountId: accountId)
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        try await store.storeInitialTokens(
            GoogleOAuthTokens(accessToken: "about-to-expire", refreshToken: "stored-refresh", expiresAt: epoch.addingTimeInterval(4 * 60)),
            accountId: accountId
        )

        let token = try await store.accessToken(for: accountId)
        #expect(token == "refreshed-access")
        #expect(refresher.refreshCallCount == 1)
    }

    @Test
    func accessTokenPersistsARotatedRefreshTokenWhenGoogleReturnsOne() async throws {
        let refresher = FakeTokenRefresher { _ in
            GoogleOAuthTokens(accessToken: "access-2", refreshToken: "rotated-refresh", expiresAt: self.epoch.addingTimeInterval(3600))
        }
        let keychain = FakeRefreshTokenStore()
        keychain.seed("original-refresh", accountId: accountId)
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        _ = try await store.accessToken(for: accountId)
        #expect(keychain.currentValue(accountId: accountId) == "rotated-refresh")
    }

    @Test
    func accessTokenThrowsMissingRefreshTokenWhenNothingIsStored() async throws {
        let refresher = FakeTokenRefresher { _ in fatalError("no refresh token to use") }
        let keychain = FakeRefreshTokenStore()
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        await #expect(throws: TokenStoreError.missingRefreshToken) {
            _ = try await store.accessToken(for: accountId)
        }
    }

    /// Plan: "リフレッシュ失敗 (invalid_grant) → アカウントを「要再認証」状態にし
    /// UI バナー" — `TokenStore` itself only owns the "detect + wipe the dead
    /// refresh token + surface a distinct error" half; `AppEnvironment`
    /// (app layer) is what turns `.reauthenticationRequired` into the
    /// account's persisted `needsReauth` flag and banner.
    @Test
    func accessTokenSurfacesReauthenticationRequiredOnInvalidGrantAndWipesTheDeadRefreshToken() async throws {
        let refresher = FakeTokenRefresher { _ in throw GoogleOAuthError.invalidGrant }
        let keychain = FakeRefreshTokenStore()
        keychain.seed("dead-refresh", accountId: accountId)
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        await #expect(throws: TokenStoreError.reauthenticationRequired) {
            _ = try await store.accessToken(for: accountId)
        }
        #expect(keychain.currentValue(accountId: accountId) == nil)
        #expect(keychain.deleteCount == 1)

        // A second call fails fast with `.missingRefreshToken` (the dead
        // token is gone) rather than calling the refresher again with the
        // same doomed token.
        await #expect(throws: TokenStoreError.missingRefreshToken) {
            _ = try await store.accessToken(for: accountId)
        }
        #expect(refresher.refreshCallCount == 1)
    }

    @Test
    func accessTokenLeavesStoredCredentialsAloneOnATransientNetworkFailure() async throws {
        struct TransientFailure: Error {}
        let refresher = FakeTokenRefresher { _ in throw TransientFailure() }
        let keychain = FakeRefreshTokenStore()
        keychain.seed("still-good-refresh", accountId: accountId)
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        await #expect(throws: TransientFailure.self) {
            _ = try await store.accessToken(for: accountId)
        }
        // Unlike `.invalidGrant`, a transient failure must not wipe the
        // still-good refresh token — the next opportunistic sync should
        // simply try refreshing again.
        #expect(keychain.currentValue(accountId: accountId) == "still-good-refresh")
        #expect(keychain.deleteCount == 0)
    }

    /// 実機バグ修正: `diagnosticScope(for:)` — `AccountEditView`の「権限の
    /// 診断」表示が使う。`accessToken(for:)`と違い、有効なキャッシュが
    /// あっても常に本物のリフレッシュを行い、Googleが返した`scope`
    /// フィールドをそのまま返す。
    @Test
    func diagnosticScopeAlwaysRefreshesAndReturnsTheGrantedScope() async throws {
        let refresher = FakeTokenRefresher { refreshToken in
            #expect(refreshToken == "stored-refresh")
            return GoogleOAuthTokens(
                accessToken: "fresh-access",
                refreshToken: nil,
                expiresAt: self.epoch.addingTimeInterval(3600),
                scope: "https://mail.google.com/ https://www.googleapis.com/auth/contacts.other.readonly"
            )
        }
        let keychain = FakeRefreshTokenStore()
        keychain.seed("stored-refresh", accountId: accountId)
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        // Seed a comfortably-valid cached access token first — unlike
        // `accessToken(for:)`, this must still force a refresh rather than
        // serving the cache (a cache hit carries no `scope` field to read).
        try await store.storeInitialTokens(
            GoogleOAuthTokens(accessToken: "cached-access", refreshToken: "stored-refresh", expiresAt: epoch.addingTimeInterval(3600)),
            accountId: accountId
        )

        let scope = try await store.diagnosticScope(for: accountId)
        #expect(scope == "https://mail.google.com/ https://www.googleapis.com/auth/contacts.other.readonly")
        #expect(refresher.refreshCallCount == 1)
    }

    @Test
    func diagnosticScopeSurfacesReauthenticationRequiredOnInvalidGrant() async throws {
        let refresher = FakeTokenRefresher { _ in throw GoogleOAuthError.invalidGrant }
        let keychain = FakeRefreshTokenStore()
        keychain.seed("dead-refresh", accountId: accountId)
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        await #expect(throws: TokenStoreError.reauthenticationRequired) {
            _ = try await store.diagnosticScope(for: accountId)
        }
        #expect(keychain.currentValue(accountId: accountId) == nil)
    }

    @Test
    func clearTokensWipesBothTheCacheAndThePersistedRefreshToken() async throws {
        let refresher = FakeTokenRefresher { _ in fatalError("should not refresh after clearing") }
        let keychain = FakeRefreshTokenStore()
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        try await store.storeInitialTokens(
            GoogleOAuthTokens(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: epoch.addingTimeInterval(3600)),
            accountId: accountId
        )
        try await store.clearTokens(for: accountId)

        #expect(keychain.currentValue(accountId: accountId) == nil)
        await #expect(throws: TokenStoreError.missingRefreshToken) {
            _ = try await store.accessToken(for: accountId)
        }
    }
}
