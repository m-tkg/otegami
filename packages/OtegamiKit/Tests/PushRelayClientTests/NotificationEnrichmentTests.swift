import Testing

@testable import PushRelayClient

/// Unit coverage for `NotificationEnrichment`/`NotificationContentPreferences`
/// — the pure title/body policy `NotificationService.swift`'s
/// `enrich(payload:)` applies. Nothing
/// here touches IMAP/GRDB/Keychain/`UNMutableNotificationContent`; that
/// end-to-end path (a real `NotificationService` process rewriting a real
/// notification's content after `xcrun simctl push`) is
/// `scripts/verify-ios-push-simulated.sh`'s job, documented in
/// `docs/verify.md`.
@Suite("NotificationEnrichment")
struct NotificationEnrichmentTests {
    @Test("shared preference keys preserve existing UserDefaults storage")
    func sharedPreferenceKeysRemainStable() {
        #expect(NotificationContentPreferences.showsSenderKey == "notification.showsSender")
        #expect(NotificationContentPreferences.showsSubjectKey == "notification.showsSubject")
        #expect(NotificationContentPreferences.showsBodyPreviewKey == "notification.showsBodyPreview")
    }

    // MARK: - needsFetch

    @Test("needsFetch is true if any one of the 3 toggles is on")
    func needsFetchTrueCases() {
        #expect(NotificationEnrichment.needsFetch(preferences: .allEnabled))
        #expect(NotificationEnrichment.needsFetch(preferences: .init(showsSender: true, showsSubject: false, showsBodyPreview: false)))
        #expect(NotificationEnrichment.needsFetch(preferences: .init(showsSender: false, showsSubject: true, showsBodyPreview: false)))
        #expect(NotificationEnrichment.needsFetch(preferences: .init(showsSender: false, showsSubject: false, showsBodyPreview: true)))
    }

    @Test("needsFetch is false only when every toggle is off")
    func needsFetchFalseOnlyWhenAllOff() {
        #expect(!NotificationEnrichment.needsFetch(preferences: .init(showsSender: false, showsSubject: false, showsBodyPreview: false)))
    }

    // MARK: - title

    @Test("title prefers a non-empty sender name over the raw address when showsSender is on")
    func titlePrefersName() {
        let title = NotificationEnrichment.title(
            preferences: .allEnabled, senderName: "田中太郎", senderAddress: "tanaka@example.com"
        )
        #expect(title == "田中太郎")
    }

    @Test("title falls back to the address when senderName is nil")
    func titleFallsBackToAddressWhenNameIsNil() {
        let title = NotificationEnrichment.title(
            preferences: .allEnabled, senderName: nil, senderAddress: "tanaka@example.com"
        )
        #expect(title == "tanaka@example.com")
    }

    @Test("title falls back to the address when senderName is the empty string")
    func titleFallsBackToAddressWhenNameIsEmpty() {
        let title = NotificationEnrichment.title(
            preferences: .allEnabled, senderName: "", senderAddress: "tanaka@example.com"
        )
        #expect(title == "tanaka@example.com")
    }

    @Test("title falls back to genericTitle when neither name nor address is available")
    func titleFallsBackToGenericWhenNothingAvailable() {
        let title = NotificationEnrichment.title(preferences: .allEnabled, senderName: nil, senderAddress: nil)
        #expect(title == NotificationEnrichment.genericTitle)
    }

    @Test("title is genericTitle when showsSender is off, even with a real sender available")
    func titleIsGenericWhenShowsSenderIsOff() {
        let preferences = NotificationContentPreferences(showsSender: false, showsSubject: true, showsBodyPreview: true)
        let title = NotificationEnrichment.title(preferences: preferences, senderName: "田中太郎", senderAddress: "tanaka@example.com")
        #expect(title == NotificationEnrichment.genericTitle)
    }

    // MARK: - body: all 8 combinations of the 3 toggles (showsSender doesn't
    // itself affect `body(preferences:...)`, but Task #176 asks for every
    // one of the 8 `NotificationContentPreferences` combinations to be
    // exercised explicitly, not just the 4 that vary `body`'s own output —
    // so each pairs one `showsSender` value with one of the 4 distinct
    // subject/bodyPreview outcomes below.)

    private static let subject = "明日の打ち合わせについて"
    private static let longBodyText = String(repeating: "あ", count: 200)
    private static let truncatedPreview = String(repeating: "あ", count: 120)

    @Test("001: sender off, subject off, bodyPreview off -> genericBody")
    func body001() {
        let preferences = NotificationContentPreferences(showsSender: false, showsSubject: false, showsBodyPreview: false)
        let body = NotificationEnrichment.body(preferences: preferences, subject: Self.subject, bodyPreviewSourceText: Self.longBodyText)
        #expect(body == NotificationEnrichment.genericBody)
    }

    @Test("010: sender off, subject off, bodyPreview on -> truncated preview only")
    func body010() {
        let preferences = NotificationContentPreferences(showsSender: false, showsSubject: false, showsBodyPreview: true)
        let body = NotificationEnrichment.body(preferences: preferences, subject: Self.subject, bodyPreviewSourceText: Self.longBodyText)
        #expect(body == Self.truncatedPreview)
    }

    @Test("011: sender off, subject on, bodyPreview off -> subject only")
    func body011() {
        let preferences = NotificationContentPreferences(showsSender: false, showsSubject: true, showsBodyPreview: false)
        let body = NotificationEnrichment.body(preferences: preferences, subject: Self.subject, bodyPreviewSourceText: Self.longBodyText)
        #expect(body == Self.subject)
    }

    @Test("100: sender off, subject on, bodyPreview on -> subject + preview")
    func body100() {
        let preferences = NotificationContentPreferences(showsSender: false, showsSubject: true, showsBodyPreview: true)
        let body = NotificationEnrichment.body(preferences: preferences, subject: Self.subject, bodyPreviewSourceText: Self.longBodyText)
        #expect(body == Self.subject + "\n" + Self.truncatedPreview)
    }

    @Test("101: sender on, subject off, bodyPreview off -> genericBody (showsSender doesn't affect body)")
    func body101() {
        let preferences = NotificationContentPreferences(showsSender: true, showsSubject: false, showsBodyPreview: false)
        let body = NotificationEnrichment.body(preferences: preferences, subject: Self.subject, bodyPreviewSourceText: Self.longBodyText)
        #expect(body == NotificationEnrichment.genericBody)
    }

    @Test("110: sender on, subject off, bodyPreview on -> truncated preview only")
    func body110() {
        let preferences = NotificationContentPreferences(showsSender: true, showsSubject: false, showsBodyPreview: true)
        let body = NotificationEnrichment.body(preferences: preferences, subject: Self.subject, bodyPreviewSourceText: Self.longBodyText)
        #expect(body == Self.truncatedPreview)
    }

    @Test("111: sender on, subject on, bodyPreview off -> subject only")
    func body111() {
        let preferences = NotificationContentPreferences(showsSender: true, showsSubject: true, showsBodyPreview: false)
        let body = NotificationEnrichment.body(preferences: preferences, subject: Self.subject, bodyPreviewSourceText: Self.longBodyText)
        #expect(body == Self.subject)
    }

    @Test("111b: sender on, subject on, bodyPreview on (all 3 on = .allEnabled) -> subject + preview")
    func body111b() {
        let body = NotificationEnrichment.body(preferences: .allEnabled, subject: Self.subject, bodyPreviewSourceText: Self.longBodyText)
        #expect(body == Self.subject + "\n" + Self.truncatedPreview)
    }

    @Test("body falls back to genericBody when subject is empty and body preview is off")
    func bodyFallsBackWhenSubjectEmpty() {
        let preferences = NotificationContentPreferences(showsSender: true, showsSubject: true, showsBodyPreview: false)
        let body = NotificationEnrichment.body(preferences: preferences, subject: "", bodyPreviewSourceText: nil)
        #expect(body == NotificationEnrichment.genericBody)
    }

    @Test("body falls back to genericBody when body preview source text is nil")
    func bodyFallsBackWhenBodyPreviewSourceIsNil() {
        let preferences = NotificationContentPreferences(showsSender: true, showsSubject: false, showsBodyPreview: true)
        let body = NotificationEnrichment.body(preferences: preferences, subject: nil, bodyPreviewSourceText: nil)
        #expect(body == NotificationEnrichment.genericBody)
    }

    @Test("body respects a custom bodyPreviewMaxLength")
    func bodyRespectsCustomMaxLength() {
        let preferences = NotificationContentPreferences(showsSender: true, showsSubject: false, showsBodyPreview: true)
        let body = NotificationEnrichment.body(
            preferences: preferences, subject: nil, bodyPreviewSourceText: Self.longBodyText, bodyPreviewMaxLength: 10
        )
        #expect(body == String(repeating: "あ", count: 10))
    }

    @Test("body collapses whitespace/newlines in the body preview, matching SnippetBuilder")
    func bodyCollapsesWhitespaceInPreview() {
        let preferences = NotificationContentPreferences(showsSender: true, showsSubject: false, showsBodyPreview: true)
        let body = NotificationEnrichment.body(
            preferences: preferences, subject: nil, bodyPreviewSourceText: "お疲れ様です。\n\n来週の件ですが、\n少しだけ　時間ください。"
        )
        #expect(body == "お疲れ様です。 来週の件ですが、 少しだけ 時間ください。")
    }
}
