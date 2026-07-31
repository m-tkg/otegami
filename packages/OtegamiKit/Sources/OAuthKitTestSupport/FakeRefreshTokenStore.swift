import Foundation
import OAuthKit

/// A trivial in-memory `RefreshTokenStoring` — see that protocol's doc
/// comment for why tests never exercise the real Keychain-backed
/// `KeychainRefreshTokenStore`. `RefreshTokenStoring`'s methods are
/// synchronous (matching `KeychainRefreshTokenStore`'s synchronous
/// `Security` framework calls), so a plain lock-protected class is enough —
/// no actor hop, no risk of the async-bridging deadlocks a semaphore-based
/// actor wrapper could hit on the cooperative thread pool.
///
/// `RefreshTokenStoring` itself is a single shared protocol (not a
/// per-provider refinement, unlike `AuthorizationSessionRunning`) — nothing
/// conforms to two providers' copies of it simultaneously, so this one type
/// is usable directly from both `GoogleOAuthTests` and `MicrosoftOAuthTests`
/// with no extra per-module conformance needed.
public final class FakeRefreshTokenStore: OAuthKit.RefreshTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    public private(set) var writeCount = 0
    public private(set) var deleteCount = 0

    public init() {}

    public func write(_ refreshToken: String, accountId: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[accountId] = refreshToken
        writeCount += 1
    }

    public func read(accountId: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[accountId]
    }

    public func delete(accountId: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[accountId] = nil
        deleteCount += 1
    }

    public func seed(_ refreshToken: String, accountId: String) {
        lock.lock(); defer { lock.unlock() }
        storage[accountId] = refreshToken
    }

    public func currentValue(accountId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[accountId]
    }
}
