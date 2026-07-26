import Testing
@testable import OtegamiCore

/// See `ModifiedUTF7`'s doc comment for why this decoder exists (Gmail's
/// Japanese system folder names arrive modified-UTF-7 encoded) and why
/// mailcore2's own equivalent wasn't reused.
@Suite("ModifiedUTF7")
struct ModifiedUTF7Tests {
    // MARK: - Real Gmail system-folder encodings
    //
    // Captured from an actual Gmail account (`docs/verify.md`'s Gmail
    // フォルダ名文字化け entry) and independently cross-checked against a
    // Python modified-UTF-7 reference implementation before being pasted
    // in here, so these fixtures don't just document what this
    // implementation happens to produce.

    @Test("decodes すべてのメール (All Mail)")
    func decodesAllMail() {
        #expect(ModifiedUTF7.decode("&MFkweTBmMG4w4TD8MOs-") == "すべてのメール")
    }

    @Test("decodes ゴミ箱 (Trash)")
    func decodesTrash() {
        #expect(ModifiedUTF7.decode("&MLQw33ux-") == "ゴミ箱")
    }

    @Test("decodes スター付き (Starred)")
    func decodesStarred() {
        #expect(ModifiedUTF7.decode("&MLkwvzD8TtgwTQ-") == "スター付き")
    }

    @Test("decodes 送信済みメール (Sent Mail)")
    func decodesSentMail() {
        #expect(ModifiedUTF7.decode("&kAFP4W4IMH8w4TD8MOs-") == "送信済みメール")
    }

    @Test("decodes 迷惑メール (Spam)")
    func decodesSpam() {
        #expect(ModifiedUTF7.decode("&j,dg0TDhMPww6w-") == "迷惑メール")
    }

    @Test("decodes 下書き (Drafts)")
    func decodesDrafts() {
        #expect(ModifiedUTF7.decode("&Tgtm+DBN-") == "下書き")
    }

    @Test("decodes 重要 (Important)")
    func decodesImportant() {
        #expect(ModifiedUTF7.decode("&kc2JgQ-") == "重要")
    }

    @Test("decodes a full [Gmail]/... path, leaving the ASCII prefix and delimiter untouched")
    func decodesFullPath() {
        #expect(ModifiedUTF7.decode("[Gmail]/&MFkweTBmMG4w4TD8MOs-") == "[Gmail]/すべてのメール")
    }

    // MARK: - RFC 3501 edge cases

    @Test("&- decodes to a literal ampersand")
    func literalAmpersand() {
        #expect(ModifiedUTF7.decode("&-") == "&")
    }

    @Test("literal ampersand round-trips through encode/decode")
    func literalAmpersandRoundTrip() {
        let text = "Q&A"
        #expect(ModifiedUTF7.decode(ModifiedUTF7.encode(text)) == text)
        #expect(ModifiedUTF7.encode(text) == "Q&-A")
    }

    @Test("plain ASCII passes through unchanged")
    func asciiPassthrough() {
        #expect(ModifiedUTF7.decode("INBOX") == "INBOX")
        #expect(ModifiedUTF7.decode("Team Updates") == "Team Updates")
    }

    @Test("plain ASCII encodes to itself")
    func asciiEncodesToItself() {
        #expect(ModifiedUTF7.encode("INBOX") == "INBOX")
    }

    @Test("mailcore2's own testMUTF7 fixture decodes correctly")
    func mailcore2ReferenceFixture() {
        // mailcore2 `unittest/unittest.swift`'s `testMUTF7()`: an
        // independent oracle (backed by CoreFoundation's
        // kCFStringEncodingUTF7_IMAP, per this decoder's doc comment) that
        // this implementation's output was checked against.
        #expect(ModifiedUTF7.decode("~peter/mail/&U,BTFw-/&ZeVnLIqe-") == "~peter/mail/台北/日本語")
    }

    @Test("malformed shift sequence (invalid character) is passed through unchanged")
    func malformedInvalidCharacter() {
        // '!' isn't in the modified BASE64 alphabet, so the run "MF!" never
        // forms a valid shift sequence and decoding must not crash.
        let input = "&MF!-"
        #expect(ModifiedUTF7.decode(input) == input)
    }

    @Test("malformed shift sequence (odd UTF-16 byte count) is passed through unchanged")
    func malformedOddByteCount() {
        // "&AA-" decodes (base64) to a single 0x00 byte — not a multiple of
        // 2, so not a whole number of UTF-16 code units.
        let input = "&AA-"
        #expect(ModifiedUTF7.decode(input) == input)
    }

    @Test("unterminated shift sequence at end of string does not crash")
    func unterminatedAtEndOfString() {
        // No trailing '-' and nothing after it: RFC 3501 permits omitting
        // '-' when it wouldn't be ambiguous, so this decodes rather than
        // erroring; the point of this test is only that it doesn't crash
        // and produces *something* stable.
        let input = "&MFkweTBmMG4w4TD8MOs"
        #expect(ModifiedUTF7.decode(input) == "すべてのメール")
    }

    @Test("bare & with nothing following is passed through unchanged")
    func bareAmpersandAtEndOfString() {
        #expect(ModifiedUTF7.decode("Sales &") == "Sales &")
    }

    @Test("empty string decodes and encodes to empty string")
    func emptyString() {
        #expect(ModifiedUTF7.decode("") == "")
        #expect(ModifiedUTF7.encode("") == "")
    }

    // MARK: - Round trips

    @Test("encode then decode round-trips Japanese folder names", arguments: [
        "すべてのメール",
        "ゴミ箱",
        "スター付き",
        "送信済みメール",
        "迷惑メール",
        "下書き",
        "重要",
    ])
    func roundTripsJapaneseNames(name: String) {
        #expect(ModifiedUTF7.decode(ModifiedUTF7.encode(name)) == name)
    }

    @Test("encode produces the exact real-world Gmail encodings")
    func encodeMatchesRealWorldEncodings() {
        #expect(ModifiedUTF7.encode("すべてのメール") == "&MFkweTBmMG4w4TD8MOs-")
        #expect(ModifiedUTF7.encode("ゴミ箱") == "&MLQw33ux-")
        #expect(ModifiedUTF7.encode("スター付き") == "&MLkwvzD8TtgwTQ-")
        #expect(ModifiedUTF7.encode("送信済みメール") == "&kAFP4W4IMH8w4TD8MOs-")
        #expect(ModifiedUTF7.encode("迷惑メール") == "&j,dg0TDhMPww6w-")
        #expect(ModifiedUTF7.encode("下書き") == "&Tgtm+DBN-")
        #expect(ModifiedUTF7.encode("重要") == "&kc2JgQ-")
    }

    @Test("decode then encode round-trips a full mailed path")
    func roundTripsFullPath() {
        let decoded = ModifiedUTF7.decode("[Gmail]/&MFkweTBmMG4w4TD8MOs-")
        #expect(ModifiedUTF7.encode(decoded) == "[Gmail]/&MFkweTBmMG4w4TD8MOs-")
    }

    @Test("round-trips text with an emoji (surrogate pair)")
    func roundTripsSurrogatePair() {
        let text = "📬 Inbox"
        let encoded = ModifiedUTF7.encode(text)
        #expect(ModifiedUTF7.decode(encoded) == text)
    }
}
