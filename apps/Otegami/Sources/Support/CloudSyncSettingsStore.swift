import Foundation

/// Persists the user-facing "iCloud でアカウントを同期" toggle
/// (`AccountsSettingsView`, M11). Deliberately a plain `UserDefaults` flag,
/// not synced through the KVS payload itself: whether *this* device
/// participates in account sync is a per-device choice (a user might want
/// their Mac to pick up iOS-added accounts but not the reverse, say), not
/// something one device should be able to flip for every other device.
///
/// Defaults to **on** (plan: "デフォルト ON") — `UserDefaults.bool(forKey:)`
/// itself defaults to `false` for a never-set key, so `isEnabled`'s getter
/// special-cases "never explicitly set" to `true` rather than just calling
/// through.
// `@unchecked Sendable`: `UserDefaults` is documented thread-safe but isn't
// declared `Sendable` in this SDK snapshot — same rationale as
// `PushSettingsStore`.
struct CloudSyncSettingsStore: @unchecked Sendable {
    private static let enabledKey = "icloudSync.accountsEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.enabledKey) != nil else { return true }
            return defaults.bool(forKey: Self.enabledKey)
        }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
}
