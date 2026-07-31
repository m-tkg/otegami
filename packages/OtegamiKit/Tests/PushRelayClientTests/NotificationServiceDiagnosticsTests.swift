import Foundation
import Testing

@testable import PushRelayClient

/// Unit coverage for `NotificationServiceDiagnostics.summarize(category:
/// underlyingDescription:)` — the pure classifier behind
/// `NotificationService`'s Task #211 diagnostic OSLog lines. No `Logger`
/// call is exercised here (not practically observable in a test); this
/// only checks the redaction/rate-limit-detection logic that feeds it.
@Suite("NotificationServiceDiagnostics")
struct NotificationServiceDiagnosticsTests {
    @Test("detects Yahoo's [LIMIT] rate-limit response (docs/architecture.md pitfall i.)")
    func detectsRateLimitedResponse() {
        let summary = NotificationServiceDiagnostics.summarize(
            category: "serverError",
            underlyingDescription: "A87 NO [LIMIT] STATUS Rate limit hit."
        )
        #expect(summary.looksRateLimited)
        #expect(summary.logDetail == "A87 NO [LIMIT] STATUS Rate limit hit.")
    }

    @Test("a plain serverError without [LIMIT] is not flagged as rate-limited")
    func plainServerErrorIsNotRateLimited() {
        let summary = NotificationServiceDiagnostics.summarize(
            category: "serverError",
            underlyingDescription: "A12 NO Mailbox does not exist."
        )
        #expect(!summary.looksRateLimited)
        #expect(summary.logDetail == "A12 NO Mailbox does not exist.")
    }

    @Test("connectionFailed keeps its description — protocol/TLS text only, safe to log")
    func connectionFailedKeepsDescription() {
        let summary = NotificationServiceDiagnostics.summarize(
            category: "connectionFailed",
            underlyingDescription: "Could not connect to the host"
        )
        #expect(summary.category == "connectionFailed")
        #expect(summary.logDetail == "Could not connect to the host")
        #expect(!summary.looksRateLimited)
    }

    @Test("authenticationFailed always drops its description, even when non-nil")
    func authenticationFailedDropsDescription() {
        let summary = NotificationServiceDiagnostics.summarize(
            category: "authenticationFailed",
            underlyingDescription: "A1 NO [AUTHENTICATIONFAILED] someone@example.com rejected"
        )
        #expect(summary.category == "authenticationFailed")
        #expect(summary.logDetail == nil)
    }

    @Test("a nil description produces a nil logDetail regardless of category")
    func nilDescriptionProducesNilLogDetail() {
        let summary = NotificationServiceDiagnostics.summarize(category: "cancelled", underlyingDescription: nil)
        #expect(summary.logDetail == nil)
        #expect(!summary.looksRateLimited)
    }

    @Test("an empty-string description produces a nil logDetail, not an empty one")
    func emptyDescriptionProducesNilLogDetail() {
        let summary = NotificationServiceDiagnostics.summarize(category: "mailboxNotFound", underlyingDescription: "")
        #expect(summary.logDetail == nil)
    }

    @Test("a description longer than maxLogDetailLength is truncated")
    func longDescriptionIsTruncated() {
        let longDescription = String(repeating: "x", count: NotificationServiceDiagnostics.maxLogDetailLength + 50)
        let summary = NotificationServiceDiagnostics.summarize(category: "serverError", underlyingDescription: longDescription)
        #expect(summary.logDetail?.count == NotificationServiceDiagnostics.maxLogDetailLength)
    }
}
