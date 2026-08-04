import Foundation

/// 押し通知起点バックグラウンド受信 Phase 1 (アプリ側反映): the Darwin
/// notification name `NotificationService` posts
/// (`CFNotificationCenterPostNotification`) right after it durably writes a
/// newly-synced message into the shared App Group database
/// (`PushTriggeredInboxSync.run`'s doc comment) — and the one the app's own
/// foreground process listens for to know it's worth re-running a GRDB
/// `Database.notifyChanges(in:)` write and let its live `ValueObservation`s
/// (mailbox/thread lists, unread counts, ...) re-fire and pick up whatever
/// the Extension just saved.
///
/// **Why Darwin notifications, not `NotificationCenter.default`**: the two
/// processes (`NotificationService`'s Extension process and the app's own)
/// share no other in-process signaling mechanism — `NotificationCenter
/// .default` only ever reaches observers within the same process.
/// `CFNotificationCenterGetDarwinNotifyCenter()` is the standard
/// cross-process primitive on Apple platforms for exactly this "some other
/// process on this device changed something, wake up and check" signal, and
/// needs no App Group/Keychain access of its own (any process on the
/// device can post/observe any name) — this app's own App Group entitlement
/// is what actually lets the two processes share the database file this
/// notification is *about*, not what lets them notify each other about it.
///
/// **Why shared here** (rather than each target keeping its own literal
/// copy, the way `OtegamiAppGroup.swift`'s doc comment explains
/// `NotificationService.swift` otherwise has to for its own Info.plist-key
/// reads): both the `Otegami` app target and the `NotificationService`
/// extension target already link this package
/// (`NotificationService.swift`'s own `import PushRelayClient`) — same
/// "one shared home instead of two must-stay-in-sync copies" reasoning
/// `PushDiagnosticsHistory.userDefaultsKey` already uses for this pair of
/// targets.
///
/// **Not app-group/bundle-id-derived** (unlike `OtegamiAppGroup.identifier`):
/// a Darwin notification name has no access-control boundary of its own, so
/// scoping it under this app's own reverse-DNS bundle id
/// (`Config/Signing.xcconfig`'s `OTEGAMI_BUNDLE_ID = com.mtkg.otegami`,
/// already hardcoded elsewhere in this codebase — e.g.
/// `NotificationService.logger`'s OSLog subsystem) is just hygiene against
/// an unlikely name collision with some other app on the same device, not a
/// security boundary — nothing secret about a bundle id already public in
/// the App Store listing.
public enum DatabaseChangeDarwinNotification {
    public static let name = "com.mtkg.otegami.db-changed"
}
