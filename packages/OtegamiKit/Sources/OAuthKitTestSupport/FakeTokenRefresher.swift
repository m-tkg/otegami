import Foundation
import OAuthKit

/// A closure-backed fake refresher — lets `TokenStoreTests` script exactly
/// what a `refresh(refreshToken:)` call should return/throw per invocation,
/// without any `URLSession`/PKCE machinery.
///
/// Generic over `Tokens` (`GoogleOAuthTokens`/`MicrosoftOAuthTokens`) rather
/// than conforming directly to either provider's `GoogleTokenRefreshing`/
/// `MicrosoftTokenRefreshing` protocol (both of which live in their own
/// package, not `OAuthKit`, and can't be depended on from here without a
/// circular dependency). `GoogleOAuthTests`/`MicrosoftOAuthTests` each add a
/// same-target, zero-code conditional extension —
/// `extension FakeTokenRefresher: GoogleTokenRefreshing where Tokens ==
/// GoogleOAuthTokens {}` — since `GoogleTokenRefreshing`'s sole requirement
/// (`func refresh(refreshToken: String) async throws -> GoogleOAuthTokens`)
/// is exactly this type's method signature once `Tokens` is fixed.
public final class FakeTokenRefresher<Tokens: OAuthTokenRepresentable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _refreshCallCount = 0
    public var refreshCallCount: Int {
        lock.withLock { _refreshCallCount }
    }

    public var handler: @Sendable (String) async throws -> Tokens

    public init(handler: @escaping @Sendable (String) async throws -> Tokens) {
        self.handler = handler
    }

    public func refresh(refreshToken: String) async throws -> Tokens {
        lock.withLock { _refreshCallCount += 1 }
        return try await handler(refreshToken)
    }
}
