import Testing
@testable import OtegamiCore

@Suite("MessageSourceFilename")
struct MessageSourceFilenameTests {
    @Test("plain ASCII subject becomes a plain filename")
    func plainSubject() {
        #expect(MessageSourceFilename.sanitized(subject: "Quarterly Report") == "Quarterly Report.eml")
    }

    @Test("Japanese subject is preserved, not stripped as non-ASCII")
    func japaneseSubject() {
        #expect(MessageSourceFilename.sanitized(subject: "会議の議事録") == "会議の議事録.eml")
    }

    @Test("path separators and other symbols are stripped, letters/digits/spaces survive")
    func symbolsStripped() {
        #expect(MessageSourceFilename.sanitized(subject: "Re: [Team] 2026/07/29 sync?!") == "Re Team 20260729 sync.eml")
    }

    @Test("nil subject falls back to 'message'")
    func nilSubject() {
        #expect(MessageSourceFilename.sanitized(subject: nil) == "message.eml")
    }

    @Test("empty subject falls back to 'message'")
    func emptySubject() {
        #expect(MessageSourceFilename.sanitized(subject: "") == "message.eml")
    }

    @Test("subject that is entirely symbols falls back to 'message'")
    func allSymbolsSubject() {
        #expect(MessageSourceFilename.sanitized(subject: "!!!★★★###") == "message.eml")
    }

    @Test("repeated/leading/trailing whitespace collapses to single spaces, trimmed")
    func whitespaceCollapsed() {
        #expect(MessageSourceFilename.sanitized(subject: "  hello    world  ") == "hello world.eml")
    }

    @Test("newlines and tabs inside the subject are treated as whitespace")
    func newlinesTreatedAsWhitespace() {
        #expect(MessageSourceFilename.sanitized(subject: "line one\nline two\ttabbed") == "line one line two tabbed.eml")
    }

    @Test("subject longer than maxLength is truncated")
    func longSubjectTruncated() {
        let longSubject = String(repeating: "a", count: 200)
        let result = MessageSourceFilename.sanitized(subject: longSubject)
        #expect(result == String(repeating: "a", count: MessageSourceFilename.maxLength) + ".eml")
    }

    @Test("a custom file extension is honored")
    func customExtension() {
        #expect(MessageSourceFilename.sanitized(subject: "notes", fileExtension: "txt") == "notes.txt")
    }

    @Test("a leading/trailing path separator attempt does not escape into a path")
    func pathSeparatorsStripped() {
        #expect(MessageSourceFilename.sanitized(subject: "../../etc/passwd") == "etcpasswd.eml")
    }
}
