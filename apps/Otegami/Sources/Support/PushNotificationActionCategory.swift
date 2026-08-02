#if os(iOS)
import UserNotifications

/// Defines the `UNNotificationCategory`/`UNNotificationAction`s a push
/// notification's action buttons ("既読にする"/"アーカイブ") use, and
/// registers them with `UNUserNotificationCenter`.
///
/// The category identifier (`"NEW_MAIL_ACTIONS"`) must match, byte-for-byte,
/// the string `server/otegami-relay-go/internal/push/apns.go` sets as the
/// APNs payload's `aps.category` — that's how iOS knows which action buttons
/// to attach to an incoming push. Both action identifiers (`"MARK_READ"`/
/// `"ARCHIVE"`) are read back out of `UNNotificationResponse.actionIdentifier`
/// by `AppDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`.
///
/// Both actions use `options: []` — no `.foreground` (the action must run in
/// the background, never bringing the app to the front), no `.destructive`
/// (styling only; archiving isn't destructive the way delete is), no
/// `.authenticationRequired` (the device is already unlocked-since-boot by
/// the time a background push action fires, same assumption
/// `KeychainCredentialStore`'s `kSecAttrAccessibleAfterFirstUnlock` already
/// makes for background sync).
///
/// `category()`/`markReadAction()`/`archiveAction()` are separated from
/// `registerPushNotificationCategories()` so a unit test can inspect the
/// assembled `UNNotificationCategory`/`UNNotificationAction` values directly,
/// without needing to mock `UNUserNotificationCenter.setNotificationCategories(_:)`
/// itself.
enum PushNotificationActionCategory {
    static let categoryIdentifier = "NEW_MAIL_ACTIONS"
    static let markReadActionIdentifier = "MARK_READ"
    static let archiveActionIdentifier = "ARCHIVE"

    static func markReadAction() -> UNNotificationAction {
        UNNotificationAction(
            identifier: markReadActionIdentifier,
            title: "既読にする",
            options: []
        )
    }

    static func archiveAction() -> UNNotificationAction {
        UNNotificationAction(
            identifier: archiveActionIdentifier,
            title: "アーカイブ",
            options: []
        )
    }

    static func category() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [markReadAction(), archiveAction()],
            intentIdentifiers: [],
            options: []
        )
    }

    /// Registers `category()` with the system — called once from
    /// `AppDelegate.application(_:didFinishLaunchingWithOptions:)`, matching
    /// the usual `UNUserNotificationCenter` setup timing (registering
    /// categories on every launch is idempotent and cheap; there's no
    /// "already registered" state to check).
    static func registerPushNotificationCategories() {
        UNUserNotificationCenter.current().setNotificationCategories([category()])
    }
}
#endif
