import Foundation

/// プッシュ通知の default action (本体タップ) から `MailScreenView` へ「開く
/// べきスレッド」を橋渡しする。`AppDelegate` は `AppEnvironment` (SwiftUI
/// `App`の`@State`) に到達できない (`PushNotificationActionHandler`のdoc
/// comment参照) ので、`PushTokenCenter`/`BadgeCenter`と同じ shared
/// singleton パターンでその制約を越える。
///
/// コールドスタート (通知タップでアプリが新規起動、`MailScreenView`の
/// `.task`がまだ/これから走る) とウォームスタート (アプリ起動中に通知
/// タップ、`.task`は二度と走らない) の両方をカバーするため、値を
/// `pendingTarget`として保持しつつ `didUpdateNotification`も飛ばす —
/// `MailScreenView`側は起動時の`.task`と`.onReceive`の両方で
/// `consumePendingTarget()`を呼び、どちらが先に走っても取りこぼさない。
@MainActor
final class PushNotificationOpenCoordinator {
    static let shared = PushNotificationOpenCoordinator()

    static let didUpdateNotification = Notification.Name("PushNotificationOpenCoordinator.didUpdate")

    private(set) var pendingTarget: PushNotificationOpenTarget?

    private init() {}

    func setPendingTarget(threadId: Int64, messageId: Int64) {
        pendingTarget = PushNotificationOpenTarget(threadId: threadId, messageId: messageId)
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: nil)
    }

    @discardableResult
    func consumePendingTarget() -> PushNotificationOpenTarget? {
        defer { pendingTarget = nil }
        return pendingTarget
    }
}

struct PushNotificationOpenTarget: Equatable {
    let threadId: Int64
    let messageId: Int64
}
