import Foundation

/// 実機フィードバック「アーカイブ時に既読にする」: `MailListSettingsView`の
/// トグル1つだけの、`SwipeActionSettingsStore`と同じ形の小さな設定ストア。
///
/// `UserDefaults.standard`直読み用の`markAsReadOnArchive`静的プロパティは
/// `MailListSettingsView`の`@AppStorage`バインディングとは別に、SwiftUI
/// ビューを介さない呼び出し元 (`MessageListView+RowActions.swift`の
/// `commitArchive`、`AccountDigestView.swift`の一括アーカイブ、
/// `ThreadDetailView+ThreadOperations.swift`の`archiveThread()`、
/// `OtegamiApp.swift`の`archiveSelectedThread()`、push 通知アクション
/// (`PushNotificationActionHandler`) 経由の`PushNotificationActionExecutor`
/// 呼び出し) から読むために用意している — `NotificationContentSettingsStore`
/// の`showsSender`等と同じ「キー未設定ならデフォルト値」パターン。
enum ArchiveActionSettingsStore {
    static let markAsReadOnArchiveKey = "archiveAction.markAsRead"
    static let defaultMarkAsReadOnArchive = false

    static var markAsReadOnArchive: Bool {
        (UserDefaults.standard.object(forKey: markAsReadOnArchiveKey) as? Bool) ?? defaultMarkAsReadOnArchive
    }
}
