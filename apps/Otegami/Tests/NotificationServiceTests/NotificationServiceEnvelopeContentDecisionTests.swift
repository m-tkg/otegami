import Foundation
import OtegamiRelayAPI
import PushRelayClient
import Testing

/// Push 通知起点バックグラウンド受信 Phase 3 (NSE のリレー先読み統合) —
/// `NotificationService.envelopeContentDecision(payload:preferences:
/// bodyPreview:)`/`shouldFetchRelayPreview(payload:preferences:)` の純粋
/// ロジックを、実IMAPセッション・共有DB・リレーへの実HTTP接続いずれも
/// 使わず検証する。`NotificationServiceParsePayloadTests`/
/// `NotificationServiceSyncFirstDecisionTests`と同じ「`NotificationService
/// .swift`自体をこのターゲットのsourcesに含めて直接コンパイルする」方式を
/// 踏襲する。
@Suite("NotificationService envelope content decision (Phase 3)")
struct NotificationServiceEnvelopeContentDecisionTests {
    private func makePayload(
        latestUid: Int64? = 41,
        latestFromName: String? = "Alice",
        latestFromAddress: String? = "alice@example.test",
        latestSubject: String? = "Hello"
    ) -> PushNotificationPayload {
        PushNotificationPayload(
            accountId: "account-1",
            uidNext: 42,
            latestUid: latestUid,
            latestFromName: latestFromName,
            latestFromAddress: latestFromAddress,
            latestSubject: latestSubject
        )
    }

    // MARK: envelopeContentDecision

    @Test("no envelope fields at all (legacy relay / feature off) yields nil — caller applies nothing")
    func noEnvelopeYieldsNil() {
        let payload = PushNotificationPayload(accountId: "account-1", uidNext: 42)
        let decision = NotificationService.envelopeContentDecision(payload: payload, preferences: .allEnabled)
        #expect(decision == nil)
    }

    @Test("an envelope with every content toggle on builds title/body straight from the payload, before any network call")
    func envelopeBuildsContentWithAllPreferencesOn() {
        let decision = NotificationService.envelopeContentDecision(payload: makePayload(), preferences: .allEnabled)
        #expect(decision?.title == "Alice")
        #expect(decision?.body == "Hello")
    }

    @Test("passing a bodyPreview appends it to the body on a second (step 2) call, same as NotificationEnrichment.body's own subject+preview ordering")
    func envelopeWithBodyPreviewAppendsSnippetLine() {
        let decision = NotificationService.envelopeContentDecision(
            payload: makePayload(), preferences: .allEnabled, bodyPreview: "本文のプレビューです"
        )
        #expect(decision?.body == "Hello\n本文のプレビューです")
    }

    @Test("showsSender off falls back to the generic title even though the payload named a sender")
    func showsSenderOffUsesGenericTitle() {
        let preferences = NotificationContentPreferences(showsSender: false, showsSubject: true, showsBodyPreview: false)
        let decision = NotificationService.envelopeContentDecision(payload: makePayload(), preferences: preferences)
        #expect(decision?.title == NotificationEnrichment.genericTitle)
        #expect(decision?.body == "Hello")
    }

    @Test("every content toggle off still returns a decision, but both fields collapse to the generic fallback text")
    func allPreferencesOffYieldsGenericText() {
        let allOff = NotificationContentPreferences(showsSender: false, showsSubject: false, showsBodyPreview: false)
        let decision = NotificationService.envelopeContentDecision(payload: makePayload(), preferences: allOff)
        #expect(decision?.title == NotificationEnrichment.genericTitle)
        #expect(decision?.body == NotificationEnrichment.genericBody)
    }

    @Test("a payload with only a subject (no from name/address) still yields a decision")
    func subjectOnlyEnvelopeStillYieldsDecision() {
        let payload = makePayload(latestFromName: nil, latestFromAddress: nil, latestSubject: "Hello")
        let decision = NotificationService.envelopeContentDecision(payload: payload, preferences: .allEnabled)
        #expect(decision != nil)
        #expect(decision?.title == NotificationEnrichment.genericTitle, "no sender info at all falls back to the generic title")
        #expect(decision?.body == "Hello")
    }

    // MARK: shouldFetchRelayPreview

    @Test("showsBodyPreview on + payload names a target uid — attempt the relay fetch")
    func shouldFetchWhenBodyPreviewOnAndUidPresent() {
        #expect(NotificationService.shouldFetchRelayPreview(payload: makePayload(latestUid: 41), preferences: .allEnabled))
    }

    @Test("showsBodyPreview off — never attempt the relay fetch, even with a uid in the payload")
    func shouldNotFetchWhenBodyPreviewOff() {
        let preferences = NotificationContentPreferences(showsSender: true, showsSubject: true, showsBodyPreview: false)
        #expect(!NotificationService.shouldFetchRelayPreview(payload: makePayload(latestUid: 41), preferences: preferences))
    }

    @Test("no latestUid in the payload — never attempt the relay fetch, even with showsBodyPreview on")
    func shouldNotFetchWhenNoLatestUid() {
        #expect(!NotificationService.shouldFetchRelayPreview(payload: makePayload(latestUid: nil), preferences: .allEnabled))
    }
}
