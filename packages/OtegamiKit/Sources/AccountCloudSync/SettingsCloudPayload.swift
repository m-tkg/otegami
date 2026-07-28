import Foundation

/// The value type behind one allowlisted `UserDefaults` key inside
/// `SettingsCloudPayload.values` — every key this feature currently syncs
/// (`AppSettingsCloudDirectory`'s allowlist) is either a plain flag or a
/// short raw-string encoding (a `RawRepresentable` enum's `rawValue`, or a
/// comma-joined list of them, per `MessageToolbarSettingsStore`/
/// `FolderCategoryOrderStore`/`SwipeActionSettingsStore`'s existing
/// "raw-string in one `UserDefaults` key" convention), so `.bool`/`.string`
/// covers every case today. Add a case here (and to `AppSettingsCloudDirectory`'s
/// allowlist) rather than reaching for a generic `Any`-typed value if a
/// future synced setting needs a different underlying type — keeping this a
/// closed, `Codable` enum is what makes the whole payload trivially
/// JSON-encodable and round-trip-testable.
public enum SettingsCloudValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case string(String)
}

/// The single JSON blob stored under `SettingsCloudSyncEngine`'s
/// `"settings.v1"` KVS key — the display-settings counterpart to
/// `AccountCloudPayload`'s `"accounts.v1"`. Unlike the account payload
/// (one entry per account, merged field-by-field), this is a single flat
/// `[key: value]` bag covering every allowlisted `UserDefaults` key at
/// once, with **one `updatedAt` timestamp for the whole payload** — the
/// plan's explicit simplification ("競合は最終更新 timestamp（ペイロード
/// 全体で1つ）の新しい方勝ちで十分"): these are independent UI
/// preferences with no cross-field invariants to protect, so there is
/// nothing a per-key timestamp would buy over "whichever device touched
/// its settings most recently wins the whole bag" — see
/// `SettingsCloudSyncEngine.reconcile()`'s doc comment for exactly how that
/// single timestamp gets compared against each device's own local state.
public struct SettingsCloudPayload: Codable, Equatable, Sendable {
    public var values: [String: SettingsCloudValue]
    public var updatedAt: Date

    public init(values: [String: SettingsCloudValue] = [:], updatedAt: Date = .distantPast) {
        self.values = values
        self.updatedAt = updatedAt
    }
}
