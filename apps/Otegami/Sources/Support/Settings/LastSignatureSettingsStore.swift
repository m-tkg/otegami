import Foundation

/// Task #162 (実機フィードバック「アカウントを切り替えたら前回の署名を覚えていて
/// ほしい」): per-account "最後に選ばれた署名 ID" memory — `ComposerView`
/// consults this whenever the From account changes (`loadAvailableSignatures()`)
/// to auto-select a signature, at the priority "前回選択 > アカウント既定署名
/// (`AccountRecord.defaultSignatureId`) > なし".
///
/// Plain `UserDefaults` reads/writes (not `@AppStorage`) — `@AppStorage`'s key
/// has to be a compile-time constant, but this needs one key *per account*
/// (`AccountRecord.id`, a UUID-shaped `String`), so the key itself is built at
/// call time instead (same "dynamic per-entity key" shape `OtegamiAccountColor`
/// /per-account settings elsewhere in this app already use when a single
/// static `@AppStorage` key can't express "one value per account").
///
/// Three-state, not `Int64?` two-state: a signature id, an explicit "なし", or
/// "never recorded anything for this account yet" all need to read back
/// distinctly (see `lastSelection(forAccountId:)`'s doc comment) — a plain
/// `Int64?` can't tell "explicitly なし" apart from "no value stored", so this
/// stores a `String` instead (`noneSentinel` for なし, absent key for never
/// recorded, the id's own decimal string otherwise).
enum LastSignatureSettingsStore {
    private static let noneSentinel = "none"

    private static func key(forAccountId accountId: String) -> String {
        "signature.lastSelectedId.\(accountId)"
    }

    /// - `nil` (outer): nothing has ever been recorded for this account —
    ///   the caller should fall back to `AccountRecord.defaultSignatureId`.
    /// - `.some(nil)`: the last explicit choice was "なし" — honor it as-is,
    ///   don't fall back to the account's default.
    /// - `.some(.some(id))`: the last explicit choice was signature `id`.
    static func lastSelection(forAccountId accountId: String) -> Int64?? {
        guard let raw = UserDefaults.standard.string(forKey: key(forAccountId: accountId)) else { return nil }
        if raw == noneSentinel { return .some(nil) }
        return .some(Int64(raw))
    }

    /// Records the user's explicit pick (`nil` = "なし") for `accountId`.
    /// Only ever called from a genuine Picker interaction
    /// (`ComposerView.selectedSignatureIdBinding`) — never from the
    /// programmatic clearing/auto-selection `loadAvailableSignatures()` does
    /// on its own, which would otherwise overwrite a real past choice with a
    /// merely-transient intermediate value during an account switch.
    static func recordSelection(_ signatureId: Int64?, forAccountId accountId: String) {
        let raw = signatureId.map(String.init) ?? noneSentinel
        UserDefaults.standard.set(raw, forKey: key(forAccountId: accountId))
    }
}
