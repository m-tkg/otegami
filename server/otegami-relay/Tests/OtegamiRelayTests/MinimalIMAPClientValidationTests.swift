import Testing

@testable import OtegamiRelay

/// CLAUDE-SECURITY F3: `MinimalIMAPClient.validateNoControlCharacters` is
/// the shared check used both by `WatchRoutes` (at `POST /v1/watches` time,
/// before anything is persisted — see `WatchRoutesTests`' CRLF-injection
/// cases) and by `MinimalIMAPClient.quoted` itself (immediately before a
/// value is written onto the wire, as a backstop for any value that
/// reaches this type by a path that skips route-level validation). These
/// tests isolate that shared check directly.
@Suite("MinimalIMAPClient.validateNoControlCharacters")
struct MinimalIMAPClientValidationTests {
    @Test(
        "rejects CR, LF, NUL, and other control characters",
        arguments: [
            "a\r\nRCPT TO:<attacker@evil.test>",
            "a\nb",
            "a\rb",
            "a\u{0000}b",
            "a\u{007F}b", // DEL
            "a\u{0001}b", // arbitrary C0 control character
        ]
    )
    func rejectsControlCharacters(value: String) {
        #expect(throws: MinimalIMAPClient.IMAPClientError.invalidControlCharacters(field: "test")) {
            try MinimalIMAPClient.validateNoControlCharacters(value, field: "test")
        }
    }

    @Test(
        "accepts ordinary values",
        arguments: [
            "user@example.com",
            "app-password-123!",
            "INBOX",
            "受信トレイ", // non-ASCII is fine — only control characters are rejected
        ]
    )
    func acceptsOrdinaryValues(value: String) throws {
        try MinimalIMAPClient.validateNoControlCharacters(value, field: "test")
    }
}
