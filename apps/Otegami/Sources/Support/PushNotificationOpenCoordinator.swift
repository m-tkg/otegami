import Foundation

/// プッシュ通知の default action (本体タップ) から `MailScreenView` へ「開く
/// べきメール」を橋渡しする。`AppDelegate` は `AppEnvironment` (SwiftUI
/// `App`の`@State`) に到達できない (`PushNotificationActionHandler`のdoc
/// comment参照) ので、`PushTokenCenter`/`BadgeCenter`と同じ shared
/// singleton パターンでその制約を越える。
///
/// ここで運ぶのは**未解決**の `accountId`/`uidNext` (プッシュペイロードその
/// まま) — 以前はタップ時点で `threadId`/`messageId` へ解決し切ってから
/// (未同期なら INBOX 優先同期まで済ませてから) 渡していたが、それだと同期が
/// 終わるまで画面遷移が起きず、失敗すると何も表示されないままになる。今は
/// タップ直後にこの request だけを積んで即座に
/// `PushNotificationOpenView` (ローディング画面) へ遷移し、解決・優先同期・
/// 失敗時の再試行はすべてそのビューが担う。
///
/// コールドスタート (通知タップでアプリが新規起動、`MailScreenView`の
/// `.task`がまだ/これから走る) とウォームスタート (アプリ起動中に通知
/// タップ、`.task`は二度と走らない) の両方をカバーするため、値を
/// `pendingRequest`として保持しつつ `didUpdateNotification`も飛ばす —
/// `MailScreenView`側は起動時の`.task`と`.onReceive`の両方で
/// `consumePendingRequest()`を呼び、どちらが先に走っても取りこぼさない。
@MainActor
final class PushNotificationOpenCoordinator {
    static let shared = PushNotificationOpenCoordinator()

    static let didUpdateNotification = Notification.Name("PushNotificationOpenCoordinator.didUpdate")

    private(set) var pendingRequest: PushNotificationOpenRequest?

    private init() {}

    func setPendingRequest(accountId: String, uidNext: Int) {
        pendingRequest = PushNotificationOpenRequest(accountId: accountId, uidNext: uidNext)
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: nil)
    }

    @discardableResult
    func consumePendingRequest() -> PushNotificationOpenRequest? {
        defer { pendingRequest = nil }
        return pendingRequest
    }
}

/// 通知タップが指す「開くべきメール」の未解決の識別子 — プッシュペイロード
/// (`accountId`/`uidNext`) そのまま。ローカル DB 上の `threadId`/`messageId`
/// への解決は `AppEnvironment.resolvePushNotificationOpenTarget` が行う。
struct PushNotificationOpenRequest: Equatable {
    let accountId: String
    let uidNext: Int
}

/// `AppEnvironment.resolvePushNotificationOpenTarget` の解決結果 —
/// `PushNotificationOpenRequest` が指すメールのローカル DB 上の位置。
struct PushNotificationOpenTarget: Equatable {
    let threadId: Int64
    let messageId: Int64
}
