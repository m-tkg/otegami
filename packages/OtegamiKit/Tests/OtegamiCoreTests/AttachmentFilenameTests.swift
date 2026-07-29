import Testing
@testable import OtegamiCore

/// Task #166 (SEC-A, findings F1/F10): `ComposerView.stageAttachments`
/// used an attacker-controlled MIME filename directly as a path component
/// before this fix — see `AttachmentFilename`'s doc comment. These cases
/// mirror the exploit scenarios from `CLAUDE-SECURITY-RESULTS.md`.
@Suite("AttachmentFilename")
struct AttachmentFilenameTests {
    @Test("a normal filename passes through unchanged")
    func normalFilename() {
        #expect(AttachmentFilename.sanitize("invoice.pdf") == "invoice.pdf")
    }

    @Test("a normal filename with spaces and symbols survives (only path separators/dots are dangerous)")
    func normalFilenameWithSymbolsSurvives() {
        #expect(AttachmentFilename.sanitize("Q3 report (final) #2.xlsx") == "Q3 report (final) #2.xlsx")
    }

    @Test("relative path traversal is neutralized")
    func relativeTraversal() {
        let result = AttachmentFilename.sanitize("../../../../../../../../Users/x/.zshrc")
        #expect(!result.contains("/"))
        #expect(!result.contains("\\"))
        #expect(!result.hasPrefix("."))
    }

    @Test("an absolute path is neutralized to a single path component")
    func absolutePath() {
        let result = AttachmentFilename.sanitize("/etc/passwd")
        #expect(!result.contains("/"))
    }

    @Test("the F10 exploit scenario filename (relative traversal to the app's own database) is neutralized")
    func f10ExploitScenario() {
        let result = AttachmentFilename.sanitize("../../otegami.sqlite")
        #expect(!result.contains("/"))
        #expect(!result.hasPrefix("."))
    }

    @Test("backslashes (Windows-style separators) are neutralized too")
    func backslashes() {
        let result = AttachmentFilename.sanitize("..\\..\\Windows\\System32\\evil.dll")
        #expect(!result.contains("\\"))
        #expect(!result.contains("/"))
    }

    @Test("a bare '..' collapses to the fallback (no separator survives, but it shouldn't read as a parent-dir reference)")
    func bareDotDot() {
        #expect(AttachmentFilename.sanitize("..") == "attachment")
    }

    @Test("a leading-dot (hidden file) filename has its dots stripped")
    func leadingDot() {
        #expect(AttachmentFilename.sanitize(".hidden") == "hidden")
    }

    @Test("nil filename falls back to 'attachment'")
    func nilFilename() {
        #expect(AttachmentFilename.sanitize(nil) == "attachment")
    }

    @Test("empty filename falls back to 'attachment'")
    func emptyFilename() {
        #expect(AttachmentFilename.sanitize("") == "attachment")
    }

    @Test("a filename that is only path separators/dots never contains a surviving separator or leading dot")
    func entirelyDangerousCharacters() {
        // Separators become "_" rather than being removed outright (so the
        // result isn't guaranteed empty/fallback here, unlike a bare ".."
        // or all-dots input — see `bareDotDot`/`allDotsFilename`), but the
        // security property that actually matters — no "/" or "\" survives
        // to be reinterpreted as introducing another path level, and the
        // result doesn't read as a hidden/parent-dir reference — must hold
        // regardless.
        let result = AttachmentFilename.sanitize("./.././/")
        #expect(!result.contains("/"))
        #expect(!result.contains("\\"))
        #expect(!result.hasPrefix("."))
        #expect(!result.isEmpty)
    }

    @Test("a filename that is entirely dots falls back to 'attachment'")
    func allDotsFilename() {
        #expect(AttachmentFilename.sanitize("...") == "attachment")
    }

    @Test("NUL bytes are neutralized")
    func nulByte() {
        let result = AttachmentFilename.sanitize("evil\0.txt")
        #expect(!result.contains("\0"))
    }

    @Test("an already-percent-decoded RFC 2231 traversal payload is neutralized")
    func rfc2231DecodedPayload() {
        // filename*=UTF-8''..%2F..%2Fotegami.sqlite decodes to this before
        // it ever reaches AttachmentFilename (decoding happens upstream in
        // RFC2231FilenameDecoder) — sanitize() must still hold once "/" is
        // literal here.
        let result = AttachmentFilename.sanitize("../../otegami.sqlite")
        #expect(!result.contains("/"))
    }

    @Test("an overly long filename is truncated to maxLength")
    func overlyLongFilename() {
        let longName = String(repeating: "a", count: 500) + ".pdf"
        let result = AttachmentFilename.sanitize(longName)
        #expect(result.count <= AttachmentFilename.maxLength)
    }

    @Test("a custom fallback is honored")
    func customFallback() {
        #expect(AttachmentFilename.sanitize("", fallback: "custom") == "custom")
        #expect(AttachmentFilename.sanitize(nil, fallback: "custom") == "custom")
    }

    @Test("non-ASCII (Japanese) filenames survive")
    func japaneseFilename() {
        #expect(AttachmentFilename.sanitize("見積書.pdf") == "見積書.pdf")
    }
}
