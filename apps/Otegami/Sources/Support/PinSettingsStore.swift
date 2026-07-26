import Foundation
import OtegamiStore

/// E9 ピン留め設定: whether pinning a message/thread also flips the IMAP
/// `\Flagged` bit (and reads other clients' `\Flagged` changes back as
/// pins), or stays a purely local-only flag otegami never puts on the wire.
///
/// Default is **off** (local-only) — the user-facing design decision this
/// implements: pinning is otegami's own feature first, with server-flag
/// interop as an opt-in for anyone who also flags mail from another client
/// and wants the two to agree. `MessageRecord.isPinnedLocal` (see
/// `AppDatabase`'s v16 migration doc comment) is always the single column
/// this app orders by, regardless of this setting — flipping the setting
/// only changes whether toggling a pin *also* touches `MessageFlags
/// .flagged`/enqueues an IMAP `setFlags` op, and whether a resync mirrors
/// the server's current `\Flagged` bit back into `isPinnedLocal`
/// (`AccountSyncer.upsert`).
///
/// Plain `UserDefaults` key (not routed through `AppEnvironment`), matching
/// `SwipeActionSettingsStore`/`TranslationSettingsStore`'s precedent: a
/// per-device UI preference with no other business logic attached doesn't
/// need a dependency-injected home. The key itself lives in
/// `OtegamiStore.PinSettingsKeys` (not here) so `SyncEngine.AccountSyncer
/// .upsert` — which needs the same flag to decide whether a resync mirrors
/// the server's `\Flagged` bit into `MessageRecord.isPinnedLocal` — can read
/// it without this app target's Settings-UI files becoming a dependency of
/// a lower-layer package; see that constant's doc comment.
public enum PinSettingsStore {
    public static let syncWithFlaggedKey = PinSettingsKeys.syncWithFlaggedKey

    public static var isSyncWithFlaggedEnabled: Bool {
        UserDefaults.standard.bool(forKey: syncWithFlaggedKey)
    }
}
