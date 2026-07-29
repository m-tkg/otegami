import Foundation
import Testing
@testable import MailTransportMailCore
import MailTransport
import OtegamiCore

/// Task #167 / F9 (`CLAUDE-SECURITY-20260729-134850/CLAUDE-SECURITY-RESULTS.md`):
/// `MailCoreSMTPSession.validateForSMTP(_:)` is the trust boundary that
/// rejects a CR/LF/NUL-carrying address or display name before it can ever
/// reach `MCOAddress`/libetpan's unescaped `RCPT TO:<%s>` command
/// construction. Exercises the validation directly (no live SMTP server
/// needed) via `@testable import`, mirroring how `SMTPAuthFallbackTests`
/// already tests `isRetriableWithoutAuth`.
struct SMTPAddressValidationTests {
    @Test("a normal address/display name passes validation")
    func normalAddressPasses() throws {
        try MailCoreSMTPSession.validateForSMTP(EmailAddress(name: "Aiko", address: "aiko@otegami.test"))
        try MailCoreSMTPSession.validateForSMTP(EmailAddress(address: "bob@otegami.test"))
    }

    @Test("an address with an embedded CRLF is rejected")
    func crlfInAddressRejected() {
        let address = EmailAddress(address: "bob@otegami.test>\r\nRCPT TO:<attacker@evil.test")
        #expect(throws: MailTransportError.self) {
            try MailCoreSMTPSession.validateForSMTP(address)
        }
    }

    @Test("an address with just a bare LF is rejected")
    func bareLFInAddressRejected() {
        let address = EmailAddress(address: "bob@otegami.test\nMAIL FROM:<attacker@evil.test>")
        #expect(throws: MailTransportError.self) {
            try MailCoreSMTPSession.validateForSMTP(address)
        }
    }

    @Test("an address containing NUL is rejected")
    func nulInAddressRejected() {
        let address = EmailAddress(address: "bob@otegami.test\u{0}attacker@evil.test")
        #expect(throws: MailTransportError.self) {
            try MailCoreSMTPSession.validateForSMTP(address)
        }
    }

    @Test("a display name with an embedded CRLF is rejected even when the address itself is clean")
    func crlfInDisplayNameRejected() {
        let address = EmailAddress(name: "Bob\r\nRCPT TO:<attacker@evil.test>", address: "bob@otegami.test")
        #expect(throws: MailTransportError.self) {
            try MailCoreSMTPSession.validateForSMTP(address)
        }
    }

    @Test("containsSMTPUnsafeBytes flags CR, LF, and NUL but not ordinary text")
    func containsSMTPUnsafeBytesDetection() {
        #expect(MailCoreSMTPSession.containsSMTPUnsafeBytes("a\rb"))
        #expect(MailCoreSMTPSession.containsSMTPUnsafeBytes("a\nb"))
        #expect(MailCoreSMTPSession.containsSMTPUnsafeBytes("a\u{0}b"))
        #expect(!MailCoreSMTPSession.containsSMTPUnsafeBytes("普通の表示名 Bob"))
    }
}
