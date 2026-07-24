import Foundation

/// Abstracts `NSUbiquitousKeyValueStore` down to the handful of operations
/// `AccountCloudSyncEngine` actually needs, so
/// `AccountCloudSyncTests`/`AccountCloudSyncEngineTests` can drive the
/// reconcile logic against an in-memory fake instead of the real iCloud KVS
/// (which, per Apple's own documentation, can silently no-op or behave like
/// local-only storage in a simulator/unsigned-build environment — exactly
/// the kind of nondeterminism a unit test needs to avoid). Mirrors
/// `GoogleOAuth.RefreshTokenStoring`'s reason for existing.
public protocol UbiquitousStoring: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func removeObject(forKey key: String)
    /// `NSUbiquitousKeyValueStore.synchronize()` is documented as "not
    /// generally necessary" (the store auto-syncs periodically) but cheap
    /// to call right after a write to nudge an upload sooner — see
    /// `AccountCloudSyncEngine.savePayload`'s call site. Returns whether the
    /// in-memory store had anything worth flushing; not otherwise acted on.
    @discardableResult func synchronize() -> Bool
}

/// Production `UbiquitousStoring`, backed by the real
/// `NSUbiquitousKeyValueStore.default`. `@unchecked Sendable`: `Foundation`
/// documents `NSUbiquitousKeyValueStore` as safe to use from any thread
/// (it's KVO/notification-based, like `UserDefaults`, which this project's
/// own `PushSettingsStore`/`CloudSyncSettingsStore` already treat the same
/// way), but the class itself predates `Sendable` and isn't annotated.
public struct SystemUbiquitousStore: UbiquitousStoring, @unchecked Sendable {
    private let store: NSUbiquitousKeyValueStore

    public init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
    }

    public func data(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    public func set(_ data: Data, forKey key: String) {
        store.set(data, forKey: key)
    }

    public func removeObject(forKey key: String) {
        store.removeObject(forKey: key)
    }

    @discardableResult
    public func synchronize() -> Bool {
        store.synchronize()
    }
}
