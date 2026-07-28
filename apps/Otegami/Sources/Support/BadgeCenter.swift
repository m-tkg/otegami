import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#endif

/// H「アプリアイコンの未読バッジ」— sets the app icon's unread-count badge
/// (iOS: `UNUserNotificationCenter.setBadgeCount(_:)`; macOS: `NSApplication
/// .dockTile.badgeLabel`, which needs no permission at all). Deliberately
/// independent of `PushTokenCenter`/the push-relay opt-in flow
/// (`PushSettingsStore`) — a user with no interest in the (self-hosted,
/// opt-in) push relay should still be able to see an unread badge driven
/// purely by local sync, so this requests only `.badge` authorization
/// rather than reusing `PushTokenCenter.requestAuthorization()`'s
/// `[.alert, .badge, .sound]`. If the user *has* already granted the fuller
/// push-relay permission set, this request is a no-op (iOS never re-prompts
/// for an already-decided authorization).
enum BadgeCenter {
    /// Best-effort — a denied/undetermined-and-declined request just means
    /// `setBadge(count:)` silently has no visible effect (the OS ignores
    /// `setBadgeCount` without authorization); never surfaced as an error
    /// anywhere a user would see it, matching every other push-adjacent
    /// permission flow in this app.
    ///
    /// Task #60 (シミュレータ検証基盤の整備): `OTEGAMI_UITEST_DISABLE_NOTIFICATION_PERMISSION_REQUEST`
    /// — a UITest/verify-script-only escape hatch, same `OTEGAMI_UITEST_*`
    /// launch-environment pattern as every flag in `AppEnvironment.swift`
    /// (`OTEGAMI_UITEST_DISABLE_AVATAR_SOURCES`のドキュメントコメント参照)。
    /// `AppEnvironment.restartBadgeObservationIfNeeded`はアカウントが1件でも
    /// あれば最初の呼び出しで必ずこれを一度呼ぶため、`scripts/verify-screen.sh`
    /// のようなアカウント注入フラグ (`OTEGAMI_UITEST_INSERT_FAKE_*`) を使う
    /// tap-free 起動では、この OS の通知許可ダイアログがほぼ確実に最初の
    /// スクリーンショットへ写り込んでしまう — `simctl privacy grant
    /// notifications`はこの開発機のシミュレータランタイムでは`Operation not
    /// permitted`で使えない (`docs/verify.md`参照) ため、アプリ側にこの
    /// エスケープハッチを用意した。
    static func requestAuthorizationIfNeeded() async {
        #if os(iOS)
        guard ProcessInfo.processInfo.environment["OTEGAMI_UITEST_DISABLE_NOTIFICATION_PERMISSION_REQUEST"] != "1" else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])
        #endif
    }

    /// Sets the icon badge to `count` (0 clears it). Also mirrors `count`
    /// into the shared App Group `UserDefaults` suite (iOS only — macOS has
    /// no App Group/`NotificationService` Extension to share it with, see
    /// `OtegamiAppGroup.identifier`'s doc comment) so `NotificationService`
    /// can increment from a reasonably fresh baseline when a push arrives
    /// between sync passes (`NotificationService.enrich(payload:)`'s doc
    /// comment covers the increment side).
    static func setBadge(count: Int) {
        #if os(iOS)
        Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(count)
        }
        sharedDefaults?.set(count, forKey: sharedCountKey)
        #elseif os(macOS)
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
        #endif
    }

    /// Key `NotificationService.swift`'s own (separately-compiled, per
    /// `OtegamiAppGroup.swift`'s doc comment on why the two targets don't
    /// share source) copy of this constant must match byte-for-byte.
    static let sharedCountKey = "badge.sharedCount"

    private static var sharedDefaults: UserDefaults? {
        guard let appGroupIdentifier = OtegamiAppGroup.identifier else { return nil }
        return UserDefaults(suiteName: appGroupIdentifier)
    }
}
