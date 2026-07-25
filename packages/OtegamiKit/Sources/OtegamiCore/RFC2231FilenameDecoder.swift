import Foundation

/// Pure decoder for RFC 2231 extended MIME parameters
/// (`filename*=charset'lang'percent-encoded-bytes`, plus its
/// `filename*0*=`/`filename*1*=` continuation form), used as a fallback for
/// `Content-Disposition` headers the pinned mailcore2 revision fails to
/// parse a `filename` out of (see `docs/roadmap.md`'s "RFC 2231 ファイル名
/// のみのメール" note and `docs/verify.md`'s M8 section for how this gap was
/// discovered: mailcore2's `MCOMessageParser` only understands RFC 2047
/// encoded-word filenames, e.g. `filename="=?UTF-8?B?...?="`, not RFC
/// 2231's `filename*=...` form).
///
/// Everything here is a pure, side-effect-free string/byte transformation —
/// no I/O, no MailCore2 — so it lives in `OtegamiCore` and is unit-testable
/// in isolation. The impure half (deciding *when* to fall back, fetching the
/// raw message bytes, and patching the decoded filename back onto a
/// `MIMEPartInfo`) lives in `MailTransportMailCore` (see
/// `MailCoreIMAPSession+Mapping.applyRFC2231FilenameFallback`).
public enum RFC2231FilenameDecoder {
    /// Scans `data` — a full raw RFC 822 message, or any byte blob
    /// containing MIME part headers — for every `Content-Disposition`
    /// header that uses the RFC 2231 extended-parameter form (`filename*=`
    /// or the `filename*0*=`/`filename*1*=`/... continuation form) and
    /// returns their decoded filenames, in the order the headers appear in
    /// `data`.
    ///
    /// Deliberately scoped to *only* the extended form: a `Content-
    /// Disposition` header using a plain `filename="..."` (quoted, whether
    /// RFC 2047 encoded-word or not) is already parsed correctly by
    /// mailcore2, so it never shows up here — callers only ever need this
    /// list to patch the specific attachment parts mailcore2 left with a
    /// `nil` filename, and (assuming the message's attachment parts are
    /// walked in the same order they appear on the wire, true for every
    /// fixture and every real-world MUA this project has seen) the two
    /// orderings line up positionally.
    ///
    /// Header folding (RFC 5322 continuation lines starting with a space or
    /// tab) is unfolded before matching, so a `filename*1*=...` continuation
    /// parameter split across wrapped lines is still recognized. Malformed
    /// segments (bad percent-encoding, an unrecognized charset, a missing
    /// initial `charset'language'` prefix) are skipped rather than
    /// producing garbage — a header that fails to decode simply contributes
    /// no entry to the result, same as if it weren't RFC 2231 at all.
    public static func extendedFilenames(inRawMessage data: Data) -> [String] {
        // `.isoLatin1` never fails to decode (every byte maps 1:1 to a
        // scalar in U+0000...U+00FF), which is exactly what's wanted here:
        // this is a structural scan for ASCII header syntax
        // (`Content-Disposition:`, `filename*0*=`, ...), not a decode of
        // the message's actual text content — the RFC 2231 percent-encoded
        // payload is decoded separately, per its own declared charset, by
        // `decodeFilename(fromContentDispositionValue:)` below.
        guard let text = String(data: data, encoding: .isoLatin1) else { return [] }

        // Normalize every CRLF *and* any stray bare CR to a single LF before
        // splitting into lines — a bare trailing CR (e.g. a line that ends
        // the byte blob without a following LF) would otherwise survive
        // into the last field's value.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        var logicalLines: [String] = []
        for line in rawLines {
            if let first = line.first, first == " " || first == "\t", !logicalLines.isEmpty {
                logicalLines[logicalLines.count - 1] += line
            } else {
                logicalLines.append(String(line))
            }
        }

        var results: [String] = []
        for line in logicalLines {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.caseInsensitiveCompare("Content-Disposition") == .orderedSame else { continue }
            let value = String(line[line.index(after: colonIndex)...])
            if let filename = decodeFilename(fromContentDispositionValue: value) {
                results.append(filename)
            }
        }
        return results
    }

    /// Parses one raw `Content-Disposition` header **value** (everything
    /// after the `:`, e.g. `" attachment;\n filename*0*=UTF-8''%E8%AB..."`)
    /// and returns the decoded filename if it uses the RFC 2231 extended
    /// form, handling both the single-segment (`filename*=...`) and
    /// continuation (`filename*0*=...; filename*1*=...; ...`) shapes.
    ///
    /// Continuation segments are concatenated at the *byte* level (not the
    /// decoded-string level) before charset conversion, since a percent-
    /// encoded multi-byte character can legally be split across two
    /// segments (e.g. a 3-byte UTF-8 sequence with its first byte ending
    /// segment 0 and the rest starting segment 1) — decoding each segment
    /// to a `String` independently would corrupt exactly that case.
    ///
    /// Returns `nil` when `value` has no `filename*` parameter at all (the
    /// common case: mailcore2 already parsed a plain `filename=`), or when
    /// the extended value is malformed enough that no safe decode exists
    /// (missing `charset'language'` prefix, unrecognized charset, invalid
    /// percent-encoding, or bytes that aren't valid text in the declared
    /// charset) — callers should treat `nil` as "no fallback filename
    /// available", not "empty filename".
    public static func decodeFilename(fromContentDispositionValue value: String) -> String? {
        let parameters = splitParameters(value)

        var singleValue: String?
        var segments: [Int: (percentEncoded: Bool, value: String)] = [:]

        for (name, rawValue) in parameters {
            let lowerName = name.lowercased()
            guard lowerName.hasPrefix("filename*") else { continue }
            let suffix = lowerName.dropFirst("filename*".count)

            if suffix.isEmpty {
                // `filename*=charset'lang'value` — no continuation.
                singleValue = rawValue
                continue
            }

            var digitsPart = suffix
            var percentEncoded = false
            if digitsPart.hasSuffix("*") {
                percentEncoded = true
                digitsPart = digitsPart.dropLast()
            }
            guard !digitsPart.isEmpty, let index = Int(digitsPart) else { continue }
            segments[index] = (percentEncoded, rawValue)
        }

        if let singleValue {
            return decodeExtendedInitialValue(singleValue)
        }

        guard !segments.isEmpty else { return nil }

        let orderedIndices = segments.keys.sorted()
        var charset: String?
        var byteBuffer = Data()

        for (position, index) in orderedIndices.enumerated() {
            guard let segment = segments[index] else { continue }
            var segmentValue = segment.value

            // Only the first segment (index 0) ever carries the
            // `charset'language'` prefix, per RFC 2231 §4.1.
            if position == 0, let split = splitCharsetLanguage(segmentValue) {
                charset = split.charset
                segmentValue = split.rest
            }

            if segment.percentEncoded {
                guard let bytes = percentDecodeBytes(segmentValue) else { return nil }
                byteBuffer.append(bytes)
            } else {
                byteBuffer.append(Data(segmentValue.utf8))
            }
        }

        guard let charset, let encoding = stringEncoding(forCharset: charset) else { return nil }
        return String(data: byteBuffer, encoding: encoding)
    }

    // MARK: - Single-segment (`filename*=charset'lang'value`) decode

    private static func decodeExtendedInitialValue(_ raw: String) -> String? {
        guard let split = splitCharsetLanguage(raw) else { return nil }
        guard let bytes = percentDecodeBytes(split.rest) else { return nil }
        guard let encoding = stringEncoding(forCharset: split.charset) else { return nil }
        return String(data: bytes, encoding: encoding)
    }

    /// Splits `charset'language'rest` on its first two single quotes.
    /// `language` may legitimately be empty (`UTF-8''...`, the overwhelming
    /// common case — no `Content-Language` equivalent supplied) but must
    /// still be present as an (empty) segment; a value with fewer than two
    /// quotes at all isn't RFC 2231's extended-value form.
    private static func splitCharsetLanguage(_ raw: String) -> (charset: String, language: String, rest: String)? {
        let parts = raw.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return (String(parts[0]), String(parts[1]), String(parts[2]))
    }

    // MARK: - Parameter-list splitting

    /// Splits a `Content-Disposition` header value into `(name, value)`
    /// parameter pairs, on `;` boundaries — respecting quoted-string
    /// parameters (a `;` inside `"..."` doesn't split) even though RFC
    /// 2231's own `filename*`/`filename*N*` values are never themselves
    /// quoted, since the same value can legitimately mix an RFC 2231
    /// parameter with an ordinary quoted one (e.g. a `size="123"` alongside
    /// `filename*=...`). The leading disposition-type token (`attachment`/
    /// `inline`, which has no `=`) is silently dropped since it has no `=`
    /// to split on.
    private static func splitParameters(_ value: String) -> [(name: String, rawValue: String)] {
        var rawParts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false

        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", inQuotes {
                escaped = true
                current.append(character)
                continue
            }
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
                continue
            }
            if character == ";", !inQuotes {
                rawParts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        rawParts.append(current)

        var params: [(String, String)] = []
        for part in rawParts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[trimmed.startIndex..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            var rawValue = String(trimmed[trimmed.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if rawValue.hasPrefix("\""), rawValue.hasSuffix("\""), rawValue.count >= 2 {
                rawValue = String(rawValue.dropFirst().dropLast())
                rawValue = rawValue
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            params.append((name, rawValue))
        }
        return params
    }

    // MARK: - Percent-decoding

    /// Percent-decodes `%XX` escapes in `value` to raw bytes. `value` is
    /// expected to be ASCII (RFC 2231's `attribute-char` grammar), so this
    /// walks UTF-8 code units directly rather than `Character`s — safe
    /// because none of `%`, hex digits, or any other `attribute-char` are
    /// multi-byte in UTF-8. Returns `nil` on a truncated or non-hex escape
    /// rather than silently dropping/mis-decoding it.
    private static func percentDecodeBytes(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        var result = Data()
        result.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == UInt8(ascii: "%") {
                guard i + 2 < bytes.count,
                      let high = hexDigitValue(bytes[i + 1]),
                      let low = hexDigitValue(bytes[i + 2])
                else {
                    return nil
                }
                result.append((high << 4) | low)
                i += 3
            } else {
                result.append(byte)
                i += 1
            }
        }
        return result
    }

    private static func hexDigitValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    // MARK: - Charset resolution

    /// Maps an IANA charset name (as it appears in the `charset'language'`
    /// prefix, e.g. `"UTF-8"`, `"ISO-2022-JP"`) to a `String.Encoding`.
    /// Deliberately a small hand-picked table rather than
    /// `CFStringConvertIANACharSetNameToEncoding` (Core Foundation) — this
    /// type lives in `OtegamiCore`, which stays dependency-free and
    /// Linux-portable by convention (see the target's doc comment in
    /// `Package.swift`), and this list covers every charset this project's
    /// mail fixtures and the mail clients it's been tested against
    /// (`docs/verify.md`) actually send. An unrecognized charset decodes to
    /// `nil` (no fallback filename) rather than guessing.
    private static func stringEncoding(forCharset charset: String) -> String.Encoding? {
        switch charset.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .ascii
        case "iso-8859-1", "latin1", "iso8859-1": return .isoLatin1
        case "iso-8859-2", "iso8859-2": return .isoLatin2
        case "iso-2022-jp": return .iso2022JP
        case "shift_jis", "shift-jis", "sjis": return .shiftJIS
        case "euc-jp": return .japaneseEUC
        case "windows-1252", "cp1252": return .windowsCP1252
        default: return nil
        }
    }
}
