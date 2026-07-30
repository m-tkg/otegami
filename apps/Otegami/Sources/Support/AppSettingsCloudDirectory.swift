import AccountCloudSync
import Foundation

/// Task #89 (実機報告「再インストール後にスレッド表示設定が既定に戻る」):
/// the app's `LocalSettingsDirectory` conformance for `SettingsCloudSyncEngine`
/// — bridges its plain data operations to the real `UserDefaults.standard`
/// keys the various `*SettingsStore` types in this directory already own.
///
/// **Task #186 (「iCloud でアカウントの設定以外も全て同期して欲しい」)**:
/// widened the allowlist below to every remaining `UserDefaults`-backed
/// setting that isn't a credential, a cache, or genuinely device-local
/// state (`docs/icloud-sync.md`'s Task #186 section has the full inventory
/// and the "同期しない" rationale for each excluded item) —
/// `DefaultAccountSettingsStore`/`LinkBrowserSettingsStore`/
/// `MessagePostActionSettingsStore`/`SendCancelSettingsStore` joined the
/// static allowlist exactly like every pre-existing entry; `LastSignature
/// SettingsStore`'s per-account keys needed a different mechanism (see
/// `dynamicStringKeyPrefixes` below) since a single compile-time constant
/// key can't express "one key per account id".
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
/// - **通知系のうちデバイス固有の部分** (`PushSettingsStore`'s device id/
///   per-account watch map/enabled flag/`deviceSecret`): each device's own
///   APNs token pairs with its own watch, so syncing these would either be
///   meaningless or actively wrong on another device. Task #121 originally
///   synced the relay URL itself (`PushSettingsStore.relayURLKey`) as the
///   one exception — it was just a hostname the user typed, not
///   device-specific. Task #173 follow-up moved the relay URL to a
///   build-time value (`RelayURLConfig`, same mechanism as
///   `RelayRegistrationSecretConfig`) instead, so there's no user-typed
///   value left to sync at all; this key is no longer part of either
///   `boolDefaults`/`stringDefaults` below.
/// - **`NotificationContentSettingsStore`'s 3 keys (Task #176) are the
///   opposite case, deliberately included below**: "差出人/件名/本文
///   プレビューを表示" is a content-privacy *preference*, not device-specific
///   state like the bullet above — there's no reason a user who doesn't
///   want a subject line on their iPhone's lock screen would want it on
///   their iPad's either. The App Group mirroring those 3 keys separately
///   need for `NotificationService` to actually read them
///   (`NotificationContentSettingsStore`'s own doc comment) is unaffected
///   by whether they're *also* synced here — that mirroring always copies
///   *this* device's own current `UserDefaults.standard` value into its own
///   App Group suite, regardless of whether that value just arrived via
///   `apply(_:)` below or was set locally.
/// - **UITest 系フラグ**: every `OTEGAMI_UITEST_*`/`-otegami*` escape hatch
///   this codebase uses is a launch environment variable/argument, never a
///   `UserDefaults` key, so none of them could end up in this allowlist by
///   accident in the first place.
/// - **`CloudSyncSettingsStore.isEnabled`/`PinSettingsKeys`**: whether *this*
///   device participates in cloud sync at all is itself a per-device choice
///   (mirrors that store's own doc comment); pinned messages are a
///   transient, per-device organizational aid with no obvious "same on
///   every device" expectation.
/// - **Task #186's remaining device-local exclusions**: `PushSettingsStore`'s
///   device id/deviceSecret (already covered above); OS-level window/scene
///   restoration (macOS's own window-frame/sidebar-collapse persistence —
///   this codebase never stores a window frame or sidebar-collapsed flag in
///   its *own* `UserDefaults` keys in the first place, so there is nothing
///   here to allowlist or exclude either way); and, as always, Keychain
///   credentials and cached mail bodies/attachments, neither of which lives
///   in `UserDefaults` at all.
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
        // Task #142: 「フラグ付きのみ表示」トグル — `unreadOnlyKey`と同じ、
        // 見た目の好みを同期する対象 (`ListDisplaySettingsStore.pinnedOnlyKey`
        // のdoc comment参照)。
        ListDisplaySettingsStore.pinnedOnlyKey: ListDisplaySettingsStore.defaultPinnedOnly,
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
        AIFeaturesSettingsStore.enabledKey: AIFeaturesSettingsStore.defaultEnabled,
        // Task #113 (2): 「ボタンのラベルを表示」トグル — 他のツールバー
        // カスタマイズ設定 (`stringDefaults`の`MessageToolbarSettingsStore
        // .orderKey`) と同じ、見た目の好みを同期する対象。
        MessageToolbarSettingsStore.showsLabelsKey: MessageToolbarSettingsStore.defaultShowsLabels,
        // Task #176: the 3 push-notification content toggles — see this
        // type's doc comment ("`NotificationContentSettingsStore`'s 3 keys")
        // for why these are synced despite living next to other, deliberately
        // *un*-synced push settings.
        NotificationContentSettingsStore.showsSenderKey: NotificationContentSettingsStore.defaultShowsSender,
        NotificationContentSettingsStore.showsSubjectKey: NotificationContentSettingsStore.defaultShowsSubject,
        NotificationContentSettingsStore.showsBodyPreviewKey: NotificationContentSettingsStore.defaultShowsBodyPreview,
        // Task #186: 「メール内リンクを開くブラウザ」— a content-handling
        // preference exactly like the toggles above, not device-specific
        // (iOS-only in *effect* — `LinkBrowserSettingsStore`'s doc comment
        // — but that's a platform capability gate the UI already applies on
        // its own, not a reason to keep the stored preference itself off a
        // Mac's copy of this device's other settings).
        LinkBrowserSettingsStore.openInAppBrowserKey: LinkBrowserSettingsStore.defaultOpenInAppBrowser
    ]

    /// Every synced `String`-valued setting (a `RawRepresentable` enum's
    /// `rawValue`, or `MessageToolbarSettingsStore`/`FolderCategoryOrderStore`'s
    /// comma-joined raw-string order lists — Task #100 extended
    /// `MessageToolbarSettingsStore`'s to also carry a per-item visibility
    /// flag, same key, `MessageToolbarSettingsStore`'s doc comment has the
    /// back-compat details), paired with its own store's compiled-in
    /// default rendered the same way.
    private static let stringDefaults: [String: String] = [
        SwipeActionSettingsStore.leadingShortActionKey: SwipeActionSettingsStore.defaultLeadingShort.rawValue,
        SwipeActionSettingsStore.leadingLongActionKey: SwipeActionSettingsStore.defaultLeadingLong.rawValue,
        SwipeActionSettingsStore.trailingShortActionKey: SwipeActionSettingsStore.defaultTrailingShort.rawValue,
        SwipeActionSettingsStore.trailingLongActionKey: SwipeActionSettingsStore.defaultTrailingLong.rawValue,
        MessageToolbarSettingsStore.orderKey: MessageToolbarSettingsStore.encodedRawValue(for: MessageToolbarSettingsStore.defaultItems),
        FolderCategoryOrderStore.key: FolderCategoryOrderStore.defaultOrder.map(\.rawValue).joined(separator: ","),
        // Task #186: 「デフォルトのアカウント」— an `AccountRecord.id` (a
        // UUID, empty string = unset). Syncing a *stale* id (an account
        // deleted on this device but not yet reconciled on another, or vice
        // versa) is harmless by construction — `DefaultAccountSettingsStore`'s
        // own doc comment already documents that `ComposerView.prepare()`
        // silently falls back to the first account whenever the stored id
        // doesn't match any current one, so there is no "invalid state" this
        // sync could ever produce, only "reverts to the pre-existing
        // fallback until it resolves itself".
        DefaultAccountSettingsStore.defaultAccountIdKey: "",
        // Task #186: 「削除・アーカイブ時の挙動」— a UI preference exactly
        // like the ones already synced above, no cross-device wrinkle.
        MessagePostActionSettingsStore.afterDeleteArchiveKey: MessagePostActionSettingsStore.defaultAfterDeleteArchive.rawValue
    ]

    /// Task #186: `SendCancelSettingsStore.windowKey` (`SendCancelWindow
    /// .rawValue`, an `Int` — `0`/`5`/`10`) is stored in `UserDefaults` as a
    /// native `Int` (`@AppStorage(Int)` at every call site), not a
    /// `String`, so it can't share `stringDefaults`' read/write path:
    /// `UserDefaults.string(forKey:)` doesn't coerce a stored `Int` the way
    /// `integer(forKey:)`/`object(forKey:) as? Int` do, so reading it that
    /// way would find nothing and silently sync the compiled-in default on
    /// every device instead of the real value. The *wire* representation
    /// still reuses `SettingsCloudValue.string` (the decimal string of the
    /// `Int`, round-tripped in `currentValues()`/`apply(_:)` below) rather
    /// than adding a dedicated `.int` case to that enum — `SettingsCloudValue`'s
    /// own doc comment already flags that a new case is the right move for
    /// "a future synced setting needs a different underlying type", but
    /// Swift's synthesized `Decodable` for an enum with associated values
    /// fails decoding the *entire* surrounding `[String: SettingsCloudEntry]`
    /// dictionary the moment it hits one entry with an unrecognized case
    /// (not just that one key) — so introducing `.int` now would mean any
    /// device still running a pre-#186 build that ever sees a cloud payload
    /// containing this key stops being able to decode *any* setting from
    /// it at all, not just this one. One `Int`-shaped setting reusing
    /// `.string` avoids that cliff entirely.
    private static let intDefaults: [String: Int] = [
        SendCancelSettingsStore.windowKey: SendCancelSettingsStore.defaultWindow.rawValue
    ]

    /// Task #186: `LastSignatureSettingsStore`'s per-account "最後に選んだ
    /// 署名" keys (`"signature.lastSelectedId.<accountId>"`) can't join
    /// `stringDefaults` above — that dictionary needs one compile-time-
    /// constant key per setting, but this store has one key *per account*,
    /// a set that only exists at runtime and differs across devices/time.
    /// `currentValues()`/`apply(_:)` instead recognize any `UserDefaults`
    /// key starting with this prefix as synced, whatever account id follows
    /// it — no DB/account-list lookup needed, this device simply mirrors
    /// whatever such keys it happens to already have.
    ///
    /// **No default-value fallback (unlike every `boolDefaults`/
    /// `stringDefaults` entry)**: `currentValues()` only ever emits a key
    /// here for an account this device has *actually* recorded a selection
    /// for (mirroring `LastSignatureSettingsStore.lastSelection(forAccountId:)`'s
    /// three-state "absent means never recorded, not なし" semantics — a
    /// synthesized "" default would collide with that store's own
    /// `noneSentinel` encoding). A key absent from `freshLocalValues` isn't
    /// dropped from the cloud payload either: `SettingsCloudSyncEngine
    /// .merge()`'s Task #186 addition (see that method's doc comment)
    /// preserves any cloud entry this device has no opinion on, so another
    /// device's recorded selection for an account this device doesn't even
    /// have yet still survives this device's next push.
    ///
    /// **No tombstone/deletion path**: there is no UI action that clears a
    /// recorded selection (`LastSignatureSettingsStore.recordSelection`'s
    /// doc comment — only ever called from a real picker choice, including
    /// choosing "なし" itself, which is a *value*, not an absence). The
    /// only way such a key becomes orphaned is its owning account being
    /// deleted entirely, at which point it is simply never read again
    /// (`LastSignatureSettingsStore.lastSelection(forAccountId:)` is only
    /// ever called with an id from the *current* account list) — a
    /// harmless residual `UserDefaults`/KVS entry, the same accepted
    /// class of leftover this codebase already tolerates elsewhere (e.g.
    /// the legacy relay-URL key `PushSettingsStore.relayURLKey`'s doc
    /// comment).
    private static let dynamicStringKeyPrefixes = ["signature.lastSelectedId."]

    func currentValues() async -> [String: SettingsCloudValue] {
        var values: [String: SettingsCloudValue] = [:]
        for (key, defaultValue) in Self.boolDefaults {
            values[key] = .bool((UserDefaults.standard.object(forKey: key) as? Bool) ?? defaultValue)
        }
        for (key, defaultValue) in Self.stringDefaults {
            values[key] = .string(UserDefaults.standard.string(forKey: key) ?? defaultValue)
        }
        for (key, defaultValue) in Self.intDefaults {
            let intValue = (UserDefaults.standard.object(forKey: key) as? Int) ?? defaultValue
            values[key] = .string(String(intValue))
        }
        for (key, value) in Self.currentDynamicStringValues() {
            values[key] = .string(value)
        }
        return values
    }

    /// Every `UserDefaults.standard` key currently matching
    /// `dynamicStringKeyPrefixes`, with its live string value — see that
    /// property's doc comment for why this doesn't fall back to any default
    /// for a key it doesn't find. `dictionaryRepresentation()` returns every
    /// domain key (including unrelated system ones), so this always filters
    /// down to just the prefix match before returning anything.
    private static func currentDynamicStringValues() -> [String: String] {
        var result: [String: String] = [:]
        let all = UserDefaults.standard.dictionaryRepresentation()
        for prefix in dynamicStringKeyPrefixes {
            for (key, rawValue) in all where key.hasPrefix(prefix) {
                guard let stringValue = rawValue as? String else { continue }
                result[key] = stringValue
            }
        }
        return result
    }

    private static func isDynamicStringKey(_ key: String) -> Bool {
        dynamicStringKeyPrefixes.contains { key.hasPrefix($0) }
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
            // Only ever write a key this device itself would recognize as
            // synced — guards against a stale/foreign entry in a cloud
            // payload (e.g. one written by a future app version with a
            // since-removed key) ever creating an unrecognized `UserDefaults`
            // entry here. Each category below writes through its own native
            // `UserDefaults` type (`Bool`/`String`/`Int`, the last decoded
            // back out of the wire `.string` — `intDefaults`'s doc comment)
            // rather than one generic `switch` over `value`, since
            // `intDefaults`/dynamic keys need a decode step `boolDefaults`/
            // `stringDefaults` don't.
            if Self.boolDefaults[key] != nil {
                if case .bool(let boolValue) = value { UserDefaults.standard.set(boolValue, forKey: key) }
            } else if Self.stringDefaults[key] != nil {
                if case .string(let stringValue) = value { UserDefaults.standard.set(stringValue, forKey: key) }
            } else if Self.intDefaults[key] != nil {
                if case .string(let stringValue) = value, let intValue = Int(stringValue) {
                    UserDefaults.standard.set(intValue, forKey: key)
                }
            } else if Self.isDynamicStringKey(key) {
                if case .string(let stringValue) = value { UserDefaults.standard.set(stringValue, forKey: key) }
            }
        }
        // Task #176: a pull that changed any of `NotificationContentSettingsStore`'s
        // 3 keys (or none — this call is cheap either way) needs its App
        // Group mirror refreshed too, or another device's more restrictive
        // choice wouldn't take effect on this device's own notifications
        // until something else happened to trigger it (this device's own
        // toggle, or the next full relaunch) — see that type's doc comment.
        NotificationContentSettingsStore.mirrorToAppGroup()
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
