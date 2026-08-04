import Foundation
import OtegamiCore
import OtegamiStore
import PushRelayClient
import SyncEngine
import Testing

/// プッシュ通知起点バックグラウンド受信 Phase 1 — `NotificationService
/// .syncFirstDecision(outcome:preferences:)` の分岐ロジック
/// (成功時: 同期済み `MessageRecord` から文言/真のバッジ数を組み立てる /
/// 失敗時: `legacyEnrich` へのフォールバックを要求する) を、実IMAPセッション
/// も共有DBも使わず検証する。`NotificationServiceParsePayloadTests`と同じ
/// 「`NotificationService.swift`自体をこのターゲットのsourcesに含めて直接
/// コンパイルする」方式 (import不要でこのファイルと同じモジュール内に型が
/// ある) を踏襲する。
@Suite("NotificationService.syncFirstDecision")
struct NotificationServiceSyncFirstDecisionTests {
    private func makeMessage(
        subject: String? = "テスト件名",
        fromAddresses: [EmailAddress] = [EmailAddress(name: "Aiko", address: "aiko@otegami.test")],
        snippet: String? = "本文のプレビューです"
    ) -> MessageRecord {
        MessageRecord(
            mailboxId: 1,
            uid: 42,
            subject: subject,
            fromAddresses: fromAddresses,
            internalDate: Date(timeIntervalSince1970: 1_700_000_000),
            bodyState: .fetched,
            snippet: snippet
        )
    }

    @Test("no resolved message falls back to legacy IMAP enrichment, regardless of preferences")
    func noMessageNeedsLegacyFallback() {
        let outcome = PushTriggeredInboxSync.Outcome(message: nil, unreadCount: nil)
        let decision = NotificationService.syncFirstDecision(outcome: outcome, preferences: .allEnabled)

        #expect(decision.needsLegacyFallback)
        #expect(decision.title == nil)
        #expect(decision.body == nil)
        #expect(decision.badgeCount == nil)
    }

    @Test("a resolved message with every content toggle on builds title/body from the synced message")
    func resolvedMessageBuildsContentWhenPreferencesAllow() {
        let message = makeMessage()
        let outcome = PushTriggeredInboxSync.Outcome(message: message, unreadCount: 7)
        let decision = NotificationService.syncFirstDecision(outcome: outcome, preferences: .allEnabled)

        #expect(!decision.needsLegacyFallback)
        #expect(decision.title == "Aiko")
        #expect(decision.body == "テスト件名\n本文のプレビューです")
        #expect(decision.badgeCount == 7)
    }

    @Test("a resolved message still persists (no legacy fallback) when every content toggle is off, but builds no text")
    func resolvedMessageSkipsContentWhenPreferencesAllOff() {
        let message = makeMessage()
        let allOff = NotificationContentPreferences(showsSender: false, showsSubject: false, showsBodyPreview: false)
        let outcome = PushTriggeredInboxSync.Outcome(message: message, unreadCount: 3)
        let decision = NotificationService.syncFirstDecision(outcome: outcome, preferences: allOff)

        #expect(!decision.needsLegacyFallback)
        #expect(decision.title == nil)
        #expect(decision.body == nil)
        // The database write already happened regardless of content
        // preferences — the real unread count should still surface so the
        // badge reflects it, even though there's no text to show.
        #expect(decision.badgeCount == 3)
    }

    @Test("a resolved message with no computable unread count leaves badgeCount nil, so the existing +1 estimate stands")
    func resolvedMessageWithoutUnreadCountLeavesBadgeCountNil() {
        let outcome = PushTriggeredInboxSync.Outcome(message: makeMessage(), unreadCount: nil)
        let decision = NotificationService.syncFirstDecision(outcome: outcome, preferences: .allEnabled)

        #expect(!decision.needsLegacyFallback)
        #expect(decision.badgeCount == nil)
    }

    @Test("a sender with no display name falls back to the address, matching NotificationEnrichment.title's own rule")
    func senderWithNoNameFallsBackToAddress() {
        let message = makeMessage(fromAddresses: [EmailAddress(address: "aiko@otegami.test")])
        let outcome = PushTriggeredInboxSync.Outcome(message: message, unreadCount: 1)
        let decision = NotificationService.syncFirstDecision(outcome: outcome, preferences: .allEnabled)

        #expect(decision.title == "aiko@otegami.test")
    }

    @Test("showsSender off falls back to the generic title even though a sender was resolved")
    func showsSenderOffUsesGenericTitle() {
        let preferences = NotificationContentPreferences(showsSender: false, showsSubject: true, showsBodyPreview: false)
        let outcome = PushTriggeredInboxSync.Outcome(message: makeMessage(), unreadCount: 1)
        let decision = NotificationService.syncFirstDecision(outcome: outcome, preferences: preferences)

        #expect(decision.title == NotificationEnrichment.genericTitle)
        #expect(decision.body == "テスト件名")
    }
}
