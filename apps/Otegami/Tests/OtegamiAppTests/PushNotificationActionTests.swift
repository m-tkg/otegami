import OtegamiRelayAPI
import SyncEngine
import Testing
import UserNotifications
@testable import Otegami

/// `PushNotificationActionCategory.category()`'s assembled
/// `UNNotificationCategory`/`UNNotificationAction`s must match the relay's
/// APNs payload exactly (`server/otegami-relay-go/internal/push/apns.go`
/// sets `aps.category = "NEW_MAIL_ACTIONS"`) — a mismatch anywhere here means
/// iOS silently shows the notification with no action buttons at all rather
/// than failing loudly. `UNUserNotificationCenter.setNotificationCategories(_:)`
/// itself isn't mockable, so these tests only inspect the plain value this
/// type assembles before handing it there.
@Suite("PushNotificationActionCategory")
struct PushNotificationActionCategoryTests {
    @Test
    func categoryIdentifierMatchesTheRelaysAPNsPayload() {
        #expect(PushNotificationActionCategory.category().identifier == "NEW_MAIL_ACTIONS")
    }

    @Test
    func categoryCarriesBothActionsInOrderWithNoIntentsOrOptions() {
        let category = PushNotificationActionCategory.category()
        #expect(category.actions.map(\.identifier) == ["MARK_READ", "ARCHIVE"])
        #expect(category.intentIdentifiers.isEmpty)
        #expect(category.options.isEmpty)
    }

    @Test
    func markReadActionRunsInTheBackgroundWithNoSpecialOptions() {
        let action = PushNotificationActionCategory.markReadAction()
        #expect(action.identifier == "MARK_READ")
        #expect(action.title == "既読にする")
        #expect(action.options.isEmpty)
    }

    @Test
    func archiveActionRunsInTheBackgroundWithNoSpecialOptions() {
        let action = PushNotificationActionCategory.archiveAction()
        #expect(action.identifier == "ARCHIVE")
        #expect(action.title == "アーカイブ")
        #expect(action.options.isEmpty)
    }
}

/// `AppDelegate.action(for:)`/`AppDelegate.parsePayload(_:)` are the two
/// pure pieces `userNotificationCenter(_:didReceive:withCompletionHandler:)`
/// branches on before ever touching `PushNotificationActionHandler` — pulled
/// out as `static func`s (mirroring `NotificationService.parsePayload(_:)`'s
/// own `private` → `internal` relaxation for the same reason) because
/// `UNNotificationResponse`/`UNNotification`/`UNNotificationRequest` are
/// difficult to construct directly in a unit test.
@Suite("AppDelegate push notification action handling")
struct AppDelegatePushNotificationActionTests {
    // `SyncEngine.PushNotificationAction` isn't `Equatable` (no call site
    // needs it outside this test), so these assert via `switch` rather than
    // `#expect(... == ...)`.

    @Test
    func markReadActionIdentifierMapsToMarkReadAction() {
        guard case .markRead = AppDelegate.action(for: "MARK_READ") else {
            Issue.record("expected .markRead")
            return
        }
    }

    @Test
    func archiveActionIdentifierMapsToArchiveAction() {
        guard case .archive = AppDelegate.action(for: "ARCHIVE") else {
            Issue.record("expected .archive")
            return
        }
    }

    @Test(arguments: [
        UNNotificationDefaultActionIdentifier,
        UNNotificationDismissActionIdentifier,
        "SOME_UNKNOWN_ACTION",
    ])
    func everyOtherActionIdentifierMapsToNoAction(actionIdentifier: String) {
        #expect(AppDelegate.action(for: actionIdentifier) == nil)
    }

    @Test
    func parsePayloadSucceedsWithAccountIdAndUidNext() {
        let payload = AppDelegate.parsePayload(["accountId": "account-1", "uidNext": 42])
        #expect(payload == PushNotificationPayload(accountId: "account-1", uidNext: 42))
    }

    @Test
    func parsePayloadFailsWithoutAccountId() {
        #expect(AppDelegate.parsePayload(["uidNext": 42]) == nil)
    }

    @Test
    func parsePayloadFailsWithoutUidNext() {
        #expect(AppDelegate.parsePayload(["accountId": "account-1"]) == nil)
    }

    /// 実機バグの回帰テスト (Gmail で通知をタップしてもメールが開けない):
    /// この `parsePayload` は `NotificationService.parsePayload(_:)` と
    /// 「byte-for-byte 同じ」という約束のもと複製されているのに、Phase 3 が
    /// envelope フィールドを足したとき Extension 側だけが更新され、こちらは
    /// `accountId`/`uidNext` しか読まないままだった。その結果、本体タップの
    /// 解決だけが `uidNext - 1` の推測に取り残されていた。この期待値は
    /// `NotificationServiceParsePayloadTests.parsesEnvelopeFieldsWhenAllPresent`
    /// と同じ `userInfo`・同じ結果 — 片側だけ増えたら両方が落ちる。
    @Test
    func parsePayloadCarriesEveryEnvelopeFieldTheExtensionSideParses() {
        let userInfo: [AnyHashable: Any] = [
            "accountId": "account-1",
            "uidNext": 42,
            "latestUid": 41,
            "latestFromName": "Alice",
            "latestFromAddress": "alice@example.test",
            "latestSubject": "Hello",
            "previewCount": 3,
        ]

        let payload = AppDelegate.parsePayload(userInfo)

        #expect(payload == PushNotificationPayload(
            accountId: "account-1",
            uidNext: 42,
            latestUid: 41,
            latestFromName: "Alice",
            latestFromAddress: "alice@example.test",
            latestSubject: "Hello",
            previewCount: 3
        ))
    }

    @Test
    func parsePayloadLeavesEnvelopeFieldsNilForALegacyRelayPush() {
        // 旧リレー / RELAY_CONTENT_PREVIEW off — 従来どおり accountId/uidNext
        // だけで解決でき、対象 UID は `uidNext - 1` の推測に落ちる。
        let payload = AppDelegate.parsePayload(["accountId": "account-1", "uidNext": 42])
        #expect(payload?.latestUid == nil)
    }
}
