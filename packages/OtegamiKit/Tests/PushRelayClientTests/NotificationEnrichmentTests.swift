import Testing

@testable import PushRelayClient

/// Unit coverage for `NotificationEnrichment` — the pure title/body policy
/// `NotificationService.swift`'s `enrich(payload:)` applies (see that
/// type's own mirrored copy). Nothing here touches IMAP/GRDB/Keychain/
/// `UNMutableNotificationContent`; that end-to-end path (a real
/// `NotificationService` process rewriting a real notification's content
/// after `xcrun simctl push`) is `scripts/verify-ios-push-simulated.sh`'s
/// job, documented in `docs/verify.md`.
@Suite("NotificationEnrichment")
struct NotificationEnrichmentTests {
    @Test("title prefers a non-empty sender name over the raw address")
    func titlePrefersName() {
        #expect(NotificationEnrichment.title(senderName: "田中太郎", senderAddress: "tanaka@example.com") == "田中太郎")
    }

    @Test("title falls back to the address when senderName is nil")
    func titleFallsBackWhenNameIsNil() {
        #expect(NotificationEnrichment.title(senderName: nil, senderAddress: "tanaka@example.com") == "tanaka@example.com")
    }

    @Test("title falls back to the address when senderName is the empty string")
    func titleFallsBackWhenNameIsEmpty() {
        #expect(NotificationEnrichment.title(senderName: "", senderAddress: "tanaka@example.com") == "tanaka@example.com")
    }

    @Test("body returns the subject verbatim when non-empty")
    func bodyReturnsSubject() {
        #expect(NotificationEnrichment.body(subject: "明日の打ち合わせについて") == "明日の打ち合わせについて")
    }

    @Test("body returns nil for a nil subject, so the caller keeps its generic fallback")
    func bodyReturnsNilForNilSubject() {
        #expect(NotificationEnrichment.body(subject: nil) == nil)
    }

    @Test("body returns nil for an empty-string subject, so the caller keeps its generic fallback")
    func bodyReturnsNilForEmptySubject() {
        #expect(NotificationEnrichment.body(subject: "") == nil)
    }
}
