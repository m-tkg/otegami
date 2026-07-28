import AccountCloudSync
import Foundation

/// Task #89 (実機報告「再インストール後にスレッド表示設定が既定に戻る」):
/// the app's `LocalSettingsDirectory` conformance for `SettingsCloudSyncEngine`
/// — bridges its plain data operations to the real `UserDefaults.standard`
/// keys the various `*SettingsStore` types in this directory already own.
///
/// **Why a foreground/background diff instead of a per-write push hook**:
/// every `*SettingsStore` in this directory is read/written directly by
/// `@AppStorage` at dozens of view call sites (`MailListSettingsView`,
/// `MailViewerSettingsView`, `MessageToolbarSettingsView`, the swipe-action
/// pickers, …) with no single choke point a hook could sit behind — adding
/// one would mean threading a callback through every one of those views'
/// bindings for a feature that's supposed to be invisible plumbing. A
/// foreground/background scene-phase diff (`OtegamiApp.handleScenePhaseChange`)
/// costs one cheap `UserDefaults` read-and-compare per transition instead,
/// which is the "実装コストの低い確実な方" `reconcile()`'s doc comment
/// mentions choosing over hooking every write site.
///
/// **Allowlist, not everything in `UserDefaults`**: only the keys listed in
/// `boolKeys`/`stringKeys` below ever leave this device. Deliberately
/// excluded (`docs/icloud-sync.md`'s settings-sync section has the full
/// rationale table):
/// - **通知系** (`PushSettingsStore`'s relay URL/watch map/enabled flag): a
///   push relay endpoint and per-account watch registrations are
///   inherently device-specific (each device's own APNs token pairs with
///   its own watch) — syncing them would either be meaningless or actively
///   wrong on another device.
/// - **UITest 系フラグ**: every `OTEGAMI_UITEST_*`/`-otegami*` escape hatch
///   this codebase uses is a launch environment variable/argument, never a
///   `UserDefaults` key, so none of them could end up in this allowlist by
///   accident in the first place.
/// - **`CloudSyncSettingsStore.isEnabled`/`PinSettingsKeys`**: whether *this*
///   device participates in cloud sync at all is itself a per-device choice
///   (mirrors that store's own doc comment); pinned messages are a
///   transient, per-device organizational aid with no obvious "same on
///   every device" expectation.
struct AppSettingsCloudDirectory: LocalSettingsDirectory, @unchecked Sendable {
    /// Device-local bookkeeping key (never leaves this device — it lives
    /// entirely on the `UserDefaults` side, not the KVS side) recording the
    /// last `SettingsCloudPayload` this device either pushed or pulled. Its
    /// absence (a fresh install, *or* a reinstall — see
    /// `LocalSettingsDirectory.lastSyncedSnapshot()`'s doc comment) is what
    /// tells `SettingsCloudSyncEngine.reconcile()` to prefer pulling the
    /// cloud's payload over pushing this device's compiled-in defaults.
    private static let lastSyncedSnapshotKey = "icloudSync.settingsLastSyncedSnapshot"

    /// Every synced `Bool`-valued setting, paired with its own store's
    /// compiled-in default (used to resolve a key this device has never
    /// explicitly written, so two devices that never touched a given
    /// setting still agree it's identical).
    private static let boolDefaults: [String: Bool] = [
        ListDisplaySettingsStore.threadingKey: ListDisplaySettingsStore.defaultThreading,
        ListDisplaySettingsStore.unreadOnlyKey: ListDisplaySettingsStore.defaultUnreadOnly,
        ListDisplaySettingsStore.groupByAccountKey: ListDisplaySettingsStore.defaultGroupByAccount,
        HTMLDisplaySettingsStore.forceLightBackgroundKey: HTMLDisplaySettingsStore.defaultForceLightBackground,
        HTMLDisplaySettingsStore.autoAdjustColorsInDarkModeKey: HTMLDisplaySettingsStore.defaultAutoAdjustColorsInDarkMode,
        ImageSettingsStore.autoShowEmbeddedImagesKey: ImageSettingsStore.defaultAutoShowEmbedded,
        ImageSettingsStore.autoShowRemoteImagesKey: ImageSettingsStore.defaultAutoShowRemote,
        AvatarSourceSettingsStore.showContactPhotoKey: AvatarSourceSettingsStore.defaultShowContactPhoto,
        AvatarSourceSettingsStore.showGoogleProfilePhotoKey: AvatarSourceSettingsStore.defaultShowGoogleProfilePhoto,
        AvatarSourceSettingsStore.showGravatarKey: AvatarSourceSettingsStore.defaultShowGravatar,
        AvatarSourceSettingsStore.showCompanyLogoKey: AvatarSourceSettingsStore.defaultShowCompanyLogo,
        TranslationSettingsStore.autoTranslateEnglishKey: TranslationSettingsStore.defaultAutoTranslateEnglish,
        TranslationSettingsStore.showListSummaryKey: false,
        AIFeaturesSettingsStore.enabledKey: AIFeaturesSettingsStore.defaultEnabled
    ]

    /// Every synced `String`-valued setting (a `RawRepresentable` enum's
    /// `rawValue`, or `MessageToolbarSettingsStore`/`FolderCategoryOrderStore`'s
    /// comma-joined raw-string order lists), paired with its own store's
    /// compiled-in default rendered the same way.
    private static let stringDefaults: [String: String] = [
        SwipeActionSettingsStore.leadingShortActionKey: SwipeActionSettingsStore.defaultLeadingShort.rawValue,
        SwipeActionSettingsStore.leadingLongActionKey: SwipeActionSettingsStore.defaultLeadingLong.rawValue,
        SwipeActionSettingsStore.trailingShortActionKey: SwipeActionSettingsStore.defaultTrailingShort.rawValue,
        SwipeActionSettingsStore.trailingLongActionKey: SwipeActionSettingsStore.defaultTrailingLong.rawValue,
        MessageToolbarSettingsStore.orderKey: MessageToolbarSettingsStore.defaultOrder.map(\.rawValue).joined(separator: ","),
        FolderCategoryOrderStore.key: FolderCategoryOrderStore.defaultOrder.map(\.rawValue).joined(separator: ",")
    ]

    func currentValues() async -> [String: SettingsCloudValue] {
        var values: [String: SettingsCloudValue] = [:]
        for (key, defaultValue) in Self.boolDefaults {
            values[key] = .bool((UserDefaults.standard.object(forKey: key) as? Bool) ?? defaultValue)
        }
        for (key, defaultValue) in Self.stringDefaults {
            values[key] = .string(UserDefaults.standard.string(forKey: key) ?? defaultValue)
        }
        return values
    }

    func lastSyncedSnapshot() async -> SettingsCloudPayload? {
        guard let data = UserDefaults.standard.data(forKey: Self.lastSyncedSnapshotKey) else { return nil }
        return try? JSONDecoder.settingsSnapshot.decode(SettingsCloudPayload.self, from: data)
    }

    func saveSyncedSnapshot(_ payload: SettingsCloudPayload) async {
        guard let data = try? JSONEncoder.settingsSnapshot.encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: Self.lastSyncedSnapshotKey)
    }

    func apply(_ payload: SettingsCloudPayload) async {
        for (key, value) in payload.values {
            // Only ever write a key this device itself would sync — guards
            // against a stale/foreign entry in a cloud payload (e.g. one
            // written by a future app version with a since-removed key)
            // ever creating an unrecognized `UserDefaults` entry here.
            guard Self.boolDefaults[key] != nil || Self.stringDefaults[key] != nil else { continue }
            switch value {
            case .bool(let boolValue):
                UserDefaults.standard.set(boolValue, forKey: key)
            case .string(let stringValue):
                UserDefaults.standard.set(stringValue, forKey: key)
            }
        }
    }
}

private extension JSONEncoder {
    static let settingsSnapshot: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let settingsSnapshot: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
