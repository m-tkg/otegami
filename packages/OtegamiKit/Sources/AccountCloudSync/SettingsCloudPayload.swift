import Foundation

/// The value type behind one allowlisted `UserDefaults` key inside
/// `SettingsCloudPayload.entries` — every key this feature currently syncs
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

/// Task #144 (settings.v2): one allowlisted key's current value, plus the
/// moment *this key specifically* last changed — the per-key unit
/// `SettingsCloudPayload` now merges on. Replaces the pre-#144 "one
/// `updatedAt` for the whole bag" design (see `SettingsCloudPayload`'s doc
/// comment for why that stopped being enough).
public struct SettingsCloudEntry: Codable, Equatable, Sendable {
    public var value: SettingsCloudValue
    public var updatedAt: Date

    public init(value: SettingsCloudValue, updatedAt: Date) {
        self.value = value
        self.updatedAt = updatedAt
    }
}

/// The single JSON blob stored under `SettingsCloudSyncEngine`'s
/// `"settings.v2"` KVS key — the display-settings counterpart to
/// `AccountCloudPayload`'s `"accounts.v1"`. Unlike the account payload
/// (one entry per account, merged field-by-field), this is a single flat
/// `[key: entry]` bag covering every allowlisted `UserDefaults` key at once
/// — but as of Task #144, **each key carries its own `updatedAt`**
/// (`entries: [String: SettingsCloudEntry]`), not one timestamp for the
/// whole payload.
///
/// **History**: the original (pre-#144, `"settings.v1"`) design used a
/// single whole-payload `updatedAt` — "競合は最終更新 timestamp（ペイロード
/// 全体で1つ）の新しい方勝ちで十分" — on the theory that these are
/// independent UI preferences with no cross-field invariants to protect.
/// That held up fine for the single-key-change-at-a-time cases real usage
/// mostly produces, but had one known, documented gap (`docs/icloud-sync.md`'s
/// "積み残し (v2 移行)" section): if two devices each changed a *different*
/// setting before either synced again, whichever device's push landed last
/// won the *entire* bag, silently discarding the other device's unrelated
/// change. Task #144 (multi-device iPhone/iPad/Mac use) closes that gap by
/// giving `SettingsCloudSyncEngine.reconcile()` a per-key last-writer-wins
/// merge instead — see that type's doc comment for exactly how.
///
/// **Wire compatibility**: `Codable` conformance below reads *either* shape
/// — the current `{"entries": {...}}` (v2) or the legacy
/// `{"values": {...}, "updatedAt": ...}` (v1, every key reinterpreted as
/// sharing that one timestamp) — but only ever *encodes* the v2 shape, so
/// once any device using this type writes a payload, it's v2 from then on.
/// `SettingsCloudSyncEngine.loadPayload()` additionally falls back to
/// reading the old `"settings.v1"` KVS key (verbatim, decoded through this
/// same flexible initializer) the first time a device that has never synced
/// under `"settings.v2"` reconciles — so devices upgrading to this version
/// at different times (the same user's iPhone today, iPad next week) don't
/// each treat the other's real pre-#144 data as "cloud has nothing" and
/// push their own stale defaults over it.
public struct SettingsCloudPayload: Equatable, Sendable {
    public var entries: [String: SettingsCloudEntry]

    public init(entries: [String: SettingsCloudEntry] = [:]) {
        self.entries = entries
    }

    /// v1-shaped convenience constructor — still the natural way to build a
    /// fixture that doesn't care about per-key timestamps (every existing
    /// call site, and most tests, only ever vary one key at a time): every
    /// key in `values` shares the single `updatedAt` given here, exactly the
    /// pre-#144 payload shape reinterpreted as v2 entries.
    public init(values: [String: SettingsCloudValue], updatedAt: Date) {
        entries = values.mapValues { SettingsCloudEntry(value: $0, updatedAt: updatedAt) }
    }

    /// Just the values, discarding each entry's own timestamp — what
    /// `LocalSettingsDirectory.apply(_:)`/`currentValues()` actually read
    /// and write (plain `UserDefaults` keys have no per-key sync timestamp
    /// of their own to compare against).
    public var values: [String: SettingsCloudValue] {
        entries.mapValues(\.value)
    }

    /// The newest `updatedAt` across every entry — `.distantPast` for an
    /// empty payload (nothing has ever been synced). Exists for call sites
    /// that only need "is this payload newer than that one" as a whole
    /// (the never-synced-device bootstrap paths in `SettingsCloudSyncEngine`
    /// still work this way; only the steady-state merge is per-key).
    public var updatedAt: Date {
        entries.values.map(\.updatedAt).max() ?? .distantPast
    }
}

extension SettingsCloudPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case entries
        case values
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let entries = try container.decodeIfPresent([String: SettingsCloudEntry].self, forKey: .entries) {
            self.entries = entries
            return
        }
        // v1 compat (read-only — see this type's doc comment): the pre-#144
        // shape is a flat `values` bag plus one whole-payload `updatedAt`.
        // Reinterpret every key as sharing that same timestamp.
        let values = try container.decodeIfPresent([String: SettingsCloudValue].self, forKey: .values) ?? [:]
        let updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        entries = values.mapValues { SettingsCloudEntry(value: $0, updatedAt: updatedAt) }
    }

    public func encode(to encoder: Encoder) throws {
        // Always v2 — nothing in this package ever writes the legacy
        // `values`/`updatedAt` shape again, even for a payload that was
        // itself just decoded from a v1 blob (`init(from:)` above).
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
    }
}
