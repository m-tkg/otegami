import Foundation
import OAuthKitTestSupport
import Testing
@testable import MicrosoftOAuth

/// Mirrors `GoogleOAuthTests.TokenStoreTests` — same expiry/refresh/
/// invalid_grant shape, since `MicrosoftOAuth.TokenStore` is a deliberate
/// mirror of `GoogleOAuth.TokenStore` (see that type's doc comment).
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
            MicrosoftOAuthTokens(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: epoch.addingTimeInterval(3600)),
            accountId: accountId
        )

        #expect(try await store.accessToken(for: accountId) == "access-1")
        #expect(refresher.refreshCallCount == 0)
        #expect(keychain.currentValue(accountId: accountId) == "refresh-1")
    }

    @Test
    func storeInitialTokensPreservesTheExistingRefreshTokenWhenTheResponseOmitsOne() async throws {
        let refresher = FakeTokenRefresher { _ in fatalError("refresh should not be called") }
        let keychain = FakeRefreshTokenStore()
        keychain.seed("original-refresh", accountId: accountId)
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        try await store.storeInitialTokens(
            MicrosoftOAuthTokens(accessToken: "access-from-refresh", refreshToken: nil, expiresAt: epoch.addingTimeInterval(3600)),
            accountId: accountId
        )

        #expect(try await store.accessToken(for: accountId) == "access-from-refresh")
        #expect(keychain.currentValue(accountId: accountId) == "original-refresh")
        #expect(keychain.writeCount == 0)
    }

    @Test
    func accessTokenRefreshesWhenNoTokenIsCachedYet() async throws {
        let refresher = FakeTokenRefresher { refreshToken in
            #expect(refreshToken == "stored-refresh")
            return MicrosoftOAuthTokens(accessToken: "fresh-access", refreshToken: nil, expiresAt: self.epoch.addingTimeInterval(3600))
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
            MicrosoftOAuthTokens(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: epoch.addingTimeInterval(30 * 60)),
            accountId: accountId
        )

        #expect(try await store.accessToken(for: accountId) == "access-1")
    }

    @Test
    func accessTokenRefreshesWhenWithinFiveMinutesOfExpiry() async throws {
        let refresher = FakeTokenRefresher { _ in
            MicrosoftOAuthTokens(accessToken: "refreshed-access", refreshToken: nil, expiresAt: self.epoch.addingTimeInterval(3600))
        }
        let keychain = FakeRefreshTokenStore()
        keychain.seed("stored-refresh", accountId: accountId)
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        try await store.storeInitialTokens(
            MicrosoftOAuthTokens(accessToken: "about-to-expire", refreshToken: "stored-refresh", expiresAt: epoch.addingTimeInterval(4 * 60)),
            accountId: accountId
        )

        let token = try await store.accessToken(for: accountId)
        #expect(token == "refreshed-access")
        #expect(refresher.refreshCallCount == 1)
    }

    @Test
    func accessTokenPersistsARotatedRefreshTokenWhenMicrosoftReturnsOne() async throws {
        let refresher = FakeTokenRefresher { _ in
            MicrosoftOAuthTokens(accessToken: "access-2", refreshToken: "rotated-refresh", expiresAt: self.epoch.addingTimeInterval(3600))
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

    @Test
    func accessTokenSurfacesReauthenticationRequiredOnInvalidGrantAndWipesTheDeadRefreshToken() async throws {
        let refresher = FakeTokenRefresher { _ in throw MicrosoftOAuthError.invalidGrant }
        let keychain = FakeRefreshTokenStore()
        keychain.seed("dead-refresh", accountId: accountId)
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        await #expect(throws: TokenStoreError.reauthenticationRequired) {
            _ = try await store.accessToken(for: accountId)
        }
        #expect(keychain.currentValue(accountId: accountId) == nil)
        #expect(keychain.deleteCount == 1)

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
        #expect(keychain.currentValue(accountId: accountId) == "still-good-refresh")
        #expect(keychain.deleteCount == 0)
    }

    @Test
    func clearTokensWipesBothTheCacheAndThePersistedRefreshToken() async throws {
        let refresher = FakeTokenRefresher { _ in fatalError("should not refresh after clearing") }
        let keychain = FakeRefreshTokenStore()
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        try await store.storeInitialTokens(
            MicrosoftOAuthTokens(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: epoch.addingTimeInterval(3600)),
            accountId: accountId
        )
        try await store.clearTokens(for: accountId)

        #expect(keychain.currentValue(accountId: accountId) == nil)
        await #expect(throws: TokenStoreError.missingRefreshToken) {
            _ = try await store.accessToken(for: accountId)
        }
    }

    @Test
    func hasStoredRefreshTokenReflectsWhetherOneIsPersisted() async throws {
        let refresher = FakeTokenRefresher { _ in fatalError("should not be called") }
        let keychain = FakeRefreshTokenStore()
        let store = TokenStore(refresher: refresher, refreshTokenStore: keychain, now: { self.epoch })

        #expect(await store.hasStoredRefreshToken(for: accountId) == false)
        try await store.storeInitialTokens(
            MicrosoftOAuthTokens(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: epoch.addingTimeInterval(3600)),
            accountId: accountId
        )
        #expect(await store.hasStoredRefreshToken(for: accountId) == true)
    }
}
