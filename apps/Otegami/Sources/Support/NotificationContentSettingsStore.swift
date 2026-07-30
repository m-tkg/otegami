import Foundation
import PushRelayClient

/// Task #176 (実機フィードバック 2026-07-30「通知にタイトル、差出人、本文の
/// 一部を出すかどうかの設定を追加して」): the 3 `PushNotificationSettingsView`
/// toggles governing what `NotificationService` is allowed to put into a
/// push notification's title/body — see `PushRelayClient
/// .NotificationContentPreferences`'s doc comment for the "this is not the
/// OS-level プレビューを表示 setting" distinction, and `NotificationEnrichment`'s
/// doc comment for how the 3 booleans actually shape the title/body text.
///
/// **Storage**: `UserDefaults.standard`, exactly like every other
/// `*SettingsStore` in this directory — so `@AppStorage(showsSenderKey)`
/// bindings in `PushNotificationSettingsView` and `AppSettingsCloudDirectory`'s
/// settings.v2 allowlist (these 3 keys are listed there) work exactly the
/// same way as any other synced display setting. **But `NotificationService`
/// runs as a separate process/bundle and doesn't share `UserDefaults
/// .standard`** (`OtegamiAppGroup.swift`'s doc comment on why the two
/// targets don't even share source files, let alone a defaults domain) —
/// so `mirrorToAppGroup()` copies the current value of all 3 keys into the
/// shared App Group `UserDefaults` suite (iOS only; a no-op on macOS, where
/// `OtegamiAppGroup.identifier` is always `nil` — see that property's doc
/// comment; moot anyway since macOS has no `NotificationService`). That
/// mirrored copy is what `NotificationService.swift`'s own (separately-
/// compiled, per `OtegamiAppGroup.swift`'s doc comment) reader actually
/// reads when a push arrives.
///
/// **Every write path that can change these 3 keys calls `mirrorToAppGroup()`
/// so the mirror is never stale by the time the next push arrives**:
/// - `PushNotificationSettingsView`'s 3 toggles call it directly from their
///   own `onChange` (this device's own change).
/// - `AppSettingsCloudDirectory.apply(_:)` calls it after every settings.v2
///   pull (another device's change arriving via iCloud).
/// - `AppEnvironment.init()` calls it once unconditionally at launch (iOS
///   only), so a value that predates this mirroring entirely (an existing
///   install upgrading to this app version, which has never run any of the
///   above two paths yet) still reaches the App Group copy before the next
///   push, rather than waiting on the user to open this settings screen or
///   for iCloud sync to fire.
enum NotificationContentSettingsStore {
    static let showsSenderKey = "notification.showsSender"
    static let showsSubjectKey = "notification.showsSubject"
    static let showsBodyPreviewKey = "notification.showsBodyPreview"

    /// Every toggle defaults to on — Task #176 must not change existing
    /// behavior for a user who never opens this settings screen at all.
    static let defaultShowsSender = true
    static let defaultShowsSubject = true
    static let defaultShowsBodyPreview = true

    static var showsSender: Bool {
        (UserDefaults.standard.object(forKey: showsSenderKey) as? Bool) ?? defaultShowsSender
    }

    static var showsSubject: Bool {
        (UserDefaults.standard.object(forKey: showsSubjectKey) as? Bool) ?? defaultShowsSubject
    }

    static var showsBodyPreview: Bool {
        (UserDefaults.standard.object(forKey: showsBodyPreviewKey) as? Bool) ?? defaultShowsBodyPreview
    }

    static var preferences: NotificationContentPreferences {
        NotificationContentPreferences(showsSender: showsSender, showsSubject: showsSubject, showsBodyPreview: showsBodyPreview)
    }

    /// Copies the current value of all 3 keys (whatever `UserDefaults
    /// .standard` has, or each one's default) into the shared App Group
    /// suite — see this type's doc comment for every call site and why
    /// each one needs to. iOS only; a silent no-op on macOS/when the App
    /// Group container isn't reachable for any other reason (mirrors
    /// `BadgeCenter.setBadge(count:)`'s existing `sharedDefaults`
    /// mirroring, same reasoning).
    static func mirrorToAppGroup() {
        #if os(iOS)
        guard let appGroupIdentifier = OtegamiAppGroup.identifier,
              let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier)
        else { return }
        sharedDefaults.set(showsSender, forKey: showsSenderKey)
        sharedDefaults.set(showsSubject, forKey: showsSubjectKey)
        sharedDefaults.set(showsBodyPreview, forKey: showsBodyPreviewKey)
        #endif
    }
}
