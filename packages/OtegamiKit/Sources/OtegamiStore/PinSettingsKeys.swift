import Foundation

/// ピン留め (E9): the `UserDefaults` key for "サーバーのフラグ (`\Flagged`) と連動
/// させる", shared between the app target's `PinSettingsStore` (the
/// `@AppStorage`/Settings-UI side) and `SyncEngine.AccountSyncer.upsert`
/// (which needs the same flag to decide whether a resync mirrors the
/// server's `\Flagged` bit into `MessageRecord.isPinnedLocal`). Lives here,
/// in `OtegamiStore`, rather than in the app target — both a lower-layer
/// package (`SyncEngine`) and the app UI already depend on `OtegamiStore`,
/// so this is the lowest common ancestor that avoids either (a) `SyncEngine`
/// depending on app-target settings files it otherwise has no reason to
/// import, or (b) two independently-typed literal string constants that
/// could silently drift apart.
public enum PinSettingsKeys {
    public static let syncWithFlaggedKey = "pinning.syncWithFlagged"
}
