import Foundation
import Testing
@testable import OtegamiCore

@Suite("RFC2231FilenameDecoder")
struct RFC2231FilenameDecoderTests {
    // MARK: - Single-segment `filename*=`

    @Test("decodes a single-segment UTF-8 filename*=")
    func decodesUTF8SingleSegment() {
        let value = #"attachment; filename*=UTF-8''%E8%AB%8B%E6%B1%82%E6%9B%B8.pdf"#
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: value) == "請求書.pdf")
    }

    @Test("decodes a single-segment ISO-2022-JP filename*=")
    func decodesISO2022JPSingleSegment() throws {
        // Encode "請求書.pdf" as real ISO-2022-JP bytes (rather than
        // hand-transcribing JIS X 0208 code points, which is error-prone)
        // and percent-encode those bytes, mirroring what a real MUA would
        // put on the wire.
        let iso2022jp = try #require("請求書.pdf".data(using: .iso2022JP))
        let percentEncoded = iso2022jp.map { String(format: "%%%02X", $0) }.joined()
        let value = "attachment; filename*=ISO-2022-JP''\(percentEncoded)"
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: value) == "請求書.pdf")
    }

    @Test("decodes with an empty language tag (the common case)")
    func decodesWithEmptyLanguage() {
        let value = "attachment; filename*=UTF-8''logo.png"
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: value) == "logo.png")
    }

    @Test("decodes with a non-empty language tag")
    func decodesWithLanguageTag() {
        let value = "attachment; filename*=UTF-8'ja'logo.png"
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: value) == "logo.png")
    }

    // MARK: - Continuation (`filename*0*=` / `filename*1*=` / ...)

    @Test("decodes a two-segment continuation, both percent-encoded")
    func decodesTwoSegmentContinuation() {
        // "請求書のファイル.pdf" split across two percent-encoded segments —
        // deliberately split *inside* a multi-byte UTF-8 sequence's byte
        // run isn't attempted here (that's the invariant-preserving test
        // below); this just checks ordinary continuation joining.
        let value = """
        attachment;
         filename*0*=UTF-8''%E8%AB%8B%E6%B1%82%E6%9B%B8%E3%81%AE%E3%83%95%E3%82%A1;
         filename*1*=%E3%82%A4%E3%83%AB.pdf
        """
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: value) == "請求書のファイル.pdf")
    }

    @Test("decodes a continuation split mid-multibyte-character without corruption")
    func decodesContinuationSplitMidCharacter() {
        // "書" is UTF-8 E6 9B B8. Split so segment 0 ends with the first two
        // bytes (E6 9B) and segment 1 starts with the last byte (B8) — only
        // valid if the two segments are concatenated at the *byte* level
        // before charset decoding, not decoded to String independently
        // (independent decoding would either crash or produce U+FFFD for
        // the truncated segment 0).
        let value = "attachment; filename*0*=UTF-8''%E6%9B; filename*1*=%B8.pdf"
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: value) == "書.pdf")
    }

    @Test("decodes a continuation whose last segment isn't percent-encoded")
    func decodesContinuationWithLiteralTrailingSegment() {
        // Per RFC 2231 §3, a continuation segment without a trailing `*` on
        // its parameter name is a literal (non-percent-encoded) value —
        // legal when that segment happens to need no encoding.
        let value = "attachment; filename*0*=UTF-8''logo; filename*1=.png"
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: value) == "logo.png")
    }

    @Test("decodes three-or-more segments in numeric order regardless of header order")
    func decodesOutOfOrderSegments() {
        let value = "attachment; filename*2*=%2E%70%64%66; filename*0*=UTF-8''%E6%9B; filename*1*=%B8"
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: value) == "書.pdf")
    }

    // MARK: - Not RFC 2231 at all (mailcore2 already handles these)

    @Test("returns nil for a plain quoted filename (no RFC 2231 parameter)")
    func returnsNilForPlainFilename() {
        let value = #"attachment; filename="invoice.pdf""#
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: value) == nil)
    }

    @Test("returns nil for an RFC 2047 encoded-word filename")
    func returnsNilForRFC2047EncodedWord() {
        // This is exactly the form `MailCoreMessageBuilder`/mailcore2
        // already parses correctly (see docs/verify.md's M8 section) — the
        // RFC 2231 decoder must stay out of its way, not "helpfully"
        // attempt to decode the encoded-word itself.
        let value = #"attachment; filename="=?UTF-8?B?6KuL5rGC5pu4LnBkZg==?=""#
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: value) == nil)
    }

    @Test("returns nil for a bare inline disposition with no filename at all")
    func returnsNilForNoFilenameParameter() {
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: "inline") == nil)
    }

    // MARK: - Malformed input

    @Test("returns nil for missing charset/language delimiters")
    func returnsNilForMissingCharsetDelimiters() {
        let value = "attachment; filename*=not-a-valid-extended-value"
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: value) == nil)
    }

    @Test("returns nil for an unrecognized charset")
    func returnsNilForUnrecognizedCharset() {
        let value = "attachment; filename*=BOGUS-CHARSET''logo.png"
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: value) == nil)
    }

    @Test("returns nil for truncated percent-encoding")
    func returnsNilForTruncatedPercentEncoding() {
        let value = "attachment; filename*=UTF-8''logo.p%"
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: value) == nil)
    }

    @Test("returns nil for invalid hex digits in a percent escape")
    func returnsNilForInvalidHexEscape() {
        let value = "attachment; filename*=UTF-8''logo%ZZ.png"
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: value) == nil)
    }

    @Test("returns nil for an empty header value")
    func returnsNilForEmptyValue() {
        #expect(RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: "") == nil)
    }

    @Test("does not crash on a continuation with a gap in segment indices")
    func toleratesGapInContinuationIndices() {
        // Missing filename*1*= entirely — still shouldn't crash; whatever
        // comes out (segment 0 and 2 concatenated) is best-effort, the
        // important invariant is "doesn't trap".
        let value = "attachment; filename*0*=UTF-8''%E6%9B; filename*2*=%2E%70%64%66"
        _ = RFC2231FilenameDecoder.decodeFilename(fromContentDispositionValue: value)
    }

    // MARK: - Whole-message scanning (`extendedFilenames(inRawMessage:)`)

    @Test("finds an RFC 2231 filename in a full raw MIME message")
    func findsFilenameInRawMessage() {
        let raw = """
        From: sender@example.com\r
        To: test1@otegami.test\r
        Subject: test\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="b"\r
        \r
        --b\r
        Content-Type: text/plain; charset=UTF-8\r
        \r
        本文\r
        --b\r
        Content-Type: application/pdf\r
        Content-Transfer-Encoding: base64\r
        Content-Disposition: attachment;\r
         filename*=UTF-8''%E8%AB%8B%E6%B1%82%E6%9B%B8.pdf\r
        \r
        JVBERi0xLjQK\r
        --b--\r
        """
        let data = Data(raw.utf8)
        #expect(RFC2231FilenameDecoder.extendedFilenames(inRawMessage: data) == ["請求書.pdf"])
    }

    @Test("finds an RFC 2231 continuation filename split across folded header lines")
    func findsFoldedContinuationFilenameInRawMessage() {
        let raw = """
        Content-Type: application/pdf\r
        Content-Disposition: attachment;\r
         filename*0*=UTF-8''%E8%AB%8B%E6%B1%82%E6%9B%B8;\r
         filename*1*=%E3%81%AE%E3%83%95%E3%82%A1%E3%82%A4%E3%83%AB.pdf\r
        \r
        base64data\r
        """
        let data = Data(raw.utf8)
        #expect(RFC2231FilenameDecoder.extendedFilenames(inRawMessage: data) == ["請求書のファイル.pdf"])
    }

    @Test("finds multiple RFC 2231 filenames in document order")
    func findsMultipleFilenamesInOrder() {
        let raw = """
        Content-Disposition: attachment; filename*=UTF-8''one.txt\r
        \r
        ---\r
        Content-Disposition: attachment; filename*=UTF-8''two.txt\r
        """
        let data = Data(raw.utf8)
        #expect(RFC2231FilenameDecoder.extendedFilenames(inRawMessage: data) == ["one.txt", "two.txt"])
    }

    @Test("skips Content-Disposition headers that aren't RFC 2231 (already-parsed filenames)")
    func skipsNonRFC2231Headers() {
        let raw = """
        Content-Disposition: attachment; filename="already-parsed.txt"\r
        \r
        Content-Disposition: attachment; filename*=UTF-8''needs-fallback.txt\r
        """
        let data = Data(raw.utf8)
        #expect(RFC2231FilenameDecoder.extendedFilenames(inRawMessage: data) == ["needs-fallback.txt"])
    }

    @Test("returns an empty list for a message with no Content-Disposition headers")
    func returnsEmptyForNoDispositionHeaders() {
        let raw = "From: a@b.com\r\nSubject: no attachments here\r\n\r\nbody text\r\n"
        #expect(RFC2231FilenameDecoder.extendedFilenames(inRawMessage: Data(raw.utf8)).isEmpty)
    }

    @Test("does not crash on arbitrary binary garbage")
    func toleratesBinaryGarbage() {
        let garbage = Data((0..<256).map { UInt8($0 % 256) })
        _ = RFC2231FilenameDecoder.extendedFilenames(inRawMessage: garbage)
    }
}
