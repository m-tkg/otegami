import Foundation

/// The local (`UserDefaults`) side of settings-cloud reconciliation,
/// abstracted the same way `LocalAccountDirectory` abstracts the local
/// (GRDB + Keychain) side of account reconciliation — so
/// `SettingsCloudSyncEngine` never touches `UserDefaults.standard`/the
/// individual `*SettingsStore` types directly, and
/// `SettingsCloudSyncEngineTests` can drive it against an in-memory fake
/// instead. The production conformer
/// (`apps/Otegami/Sources/Support/AppSettingsCloudDirectory.swift`) owns the
/// actual allowlist of which `UserDefaults` keys participate.
public protocol LocalSettingsDirectory: Sendable {
    /// Every allowlisted setting's current value, resolved against its own
    /// compiled-in default for any key that's never been explicitly written
    /// on this device — so two devices that have never touched a given
    /// setting still agree it's identical (rather than one seeing it
    /// "missing" and treating that as a difference worth pushing).
    func currentValues() async -> [String: SettingsCloudValue]

    /// This device's own record of the last payload it either pushed to or
    /// pulled from the cloud — `nil` means this device has never
    /// synced settings at all (a fresh install, including a *re*-install:
    /// this bookkeeping lives in the same `UserDefaults` the reported bug
    /// wipes, which is exactly why its absence must mean "go pull from the
    /// cloud", never "push my defaults" — see
    /// `SettingsCloudSyncEngine.reconcile()`'s doc comment).
    func lastSyncedSnapshot() async -> SettingsCloudPayload?

    /// Records `payload` as this device's new "last synced" bookkeeping —
    /// called after both a successful push (with the payload just pushed)
    /// and a successful pull (with the payload just applied), so the next
    /// `reconcile()` call has an accurate baseline to diff the next local
    /// change against.
    func saveSyncedSnapshot(_ payload: SettingsCloudPayload) async

    /// The cloud payload won — write every value it carries into this
    /// device's actual `UserDefaults` keys (the ones `currentValues()`
    /// reads back), so every `@AppStorage`-bound view picks up the change
    /// immediately. Does **not** also call `saveSyncedSnapshot` itself —
    /// the caller (`SettingsCloudSyncEngine.reconcile()`) does that
    /// explicitly with the exact payload just applied.
    func apply(_ payload: SettingsCloudPayload) async
}
