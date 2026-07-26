import Foundation

/// Pure encoder/decoder for RFC 3501 §5.1.3 "modified UTF-7" — the encoding
/// IMAP mailbox names use for anything outside printable US-ASCII (Gmail's
/// Japanese system folder names among them: `&MFkweTBmMG4w4TD8MOs-` is
/// "すべてのメール"). Distinct from RFC 2152 "UTF-7" in three ways this
/// implementation follows exactly:
///
/// - `&` (not `+`) is the shift character introducing an encoded run,
///   because plain UTF-7's shift character (`+`) is itself a valid mailbox-
///   name character IMAP servers commonly use.
/// - The modified BASE64 alphabet swaps `,` in for `/` (`/` being reserved
///   as a hierarchy delimiter on many servers) and never emits `=` padding.
/// - `&-` is the literal encoding of `&` itself, rather than shifting to an
///   empty run.
///
/// Lives in `OtegamiCore` (Linux-compatible, no MailCore2/Foundation-beyond-
/// `Data`-and-base64 dependency — `server/otegami-relay` links this target
/// on Linux) rather than `MailTransportMailCore`, so it's usable and unit-
/// testable independent of MailCore2. See `MailCoreIMAPSession
/// .mailboxInfo(from:)` for the one call site that decodes `MailboxInfo
/// .displayPath` from the server's raw path, and `AppDatabase`'s `v21`
/// migration for the one-time repair of `displayPath` values written before
/// this decoder existed (`docs/verify.md`'s Gmail フォルダ名文字化け entry
/// has the full incident writeup).
///
/// mailcore2 (the IMAP library this app links, pinned revision
/// `44c63329df67e9a0d597627edbebe65002d3fcd8`) *does* contain an equivalent
/// implementation — `mailcore::String::mUTF7DecodedString()` /
/// `.mUTF7EncodedString()` in `src/core/basetypes/MCString.cpp`, backed by
/// CoreFoundation's `kCFStringEncodingUTF7_IMAP` (a constant Apple's own
/// header explicitly documents as "UTF-7 (IMAP folder variant) RFC3501").
/// It was not reused here for two independent reasons: (1) those methods
/// are never re-exported through mailcore2's public Objective-C/Swift
/// wrapper layer (`src/objc-wrapper`) that this package's `MailCore`
/// product actually links against — only mailcore2's own internal C++ test
/// target can reach them — so calling them would mean depending on a
/// private header mailcore2 doesn't ship as part of its public API surface;
/// and (2) `kCFStringEncodingUTF7_IMAP` is CoreFoundation, i.e. Apple-only,
/// which conflicts with `OtegamiCore` staying Linux-buildable for the relay
/// server. mailcore2's C++ unit test (`unittest/unittest.swift`,
/// `testMUTF7()`) was still useful as an independent correctness oracle:
/// its fixture (`"~peter/mail/&U,BTFw-/&ZeVnLIqe-"` decoding to
/// `"~peter/mail/台北/日本語"`) round-trips correctly through both functions
/// below, alongside this file's own Gmail-folder-name fixtures.
public enum ModifiedUTF7 {
    private static let modifiedBase64Alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,"
    )
    private static let decodeTable: [Character: UInt8] = {
        var table: [Character: UInt8] = [:]
        for (index, char) in modifiedBase64Alphabet.enumerated() {
            table[char] = UInt8(index)
        }
        return table
    }()

    /// Decodes a modified-UTF-7 string (an IMAP mailbox name/path segment as
    /// received from the server) into plain Unicode text. Malformed input —
    /// an unterminated or invalid shift sequence, a shift sequence whose
    /// decoded byte count isn't a multiple of 2 (UTF-16 code units), or one
    /// that doesn't decode to valid UTF-16 — is left untouched in the
    /// output (the original `&...` run is copied through verbatim) rather
    /// than throwing or producing replacement characters: a folder name
    /// this can't parse should still be usable, not crash-inducing.
    public static func decode(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        let chars = Array(input)
        var i = 0
        let n = chars.count

        while i < n {
            let c = chars[i]
            guard c == "&" else {
                result.append(c)
                i += 1
                continue
            }

            // Collect the run of modified-BASE64 alphabet characters
            // following '&'. Per RFC 3501, the terminating '-' is only
            // mandatory when omitting it would be ambiguous (i.e. the
            // following character is itself part of the BASE64 alphabet);
            // real-world encoders (Dovecot, Gmail) always emit it, but this
            // still tolerates its absence at end-of-string.
            var j = i + 1
            while j < n, decodeTable[chars[j]] != nil {
                j += 1
            }

            if j == i + 1 {
                // "&-" (literal '&') or "&" immediately followed by a
                // non-BASE64 character/end-of-string with zero BASE64
                // characters collected.
                if j < n, chars[j] == "-" {
                    result.append("&")
                    i = j + 1
                } else {
                    // Bare "&" with no following '-' and nothing decodable:
                    // malformed — pass the '&' through unchanged.
                    result.append("&")
                    i += 1
                }
                continue
            }

            let hasExplicitTerminator = j < n && chars[j] == "-"
            let base64Chars = chars[(i + 1)..<j]

            if let decoded = decodeShiftedRun(base64Chars) {
                result.append(decoded)
                i = hasExplicitTerminator ? j + 1 : j
            } else {
                // Malformed shift sequence: emit the original text
                // (including the shift char and terminator, if any)
                // unchanged rather than dropping or crashing.
                result.append(contentsOf: chars[i..<(hasExplicitTerminator ? j + 1 : j)])
                i = hasExplicitTerminator ? j + 1 : j
            }
        }

        return result
    }

    /// Encodes plain Unicode text into modified UTF-7, for future folder-
    /// creation/rename use (not yet wired to any call site as of this
    /// writing — see this file's own doc comment). Always emits the
    /// terminating `-`, matching real-world encoders and this file's own
    /// decoder (which requires no such convention but is compatible with
    /// it either way).
    public static func encode(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var pendingShiftScalars: [UInt16] = []

        func flushShift() {
            guard !pendingShiftScalars.isEmpty else { return }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(pendingShiftScalars.count * 2)
            for unit in pendingShiftScalars {
                bytes.append(UInt8(unit >> 8))
                bytes.append(UInt8(unit & 0xFF))
            }
            result.append("&")
            result.append(encodeModifiedBase64(bytes))
            result.append("-")
            pendingShiftScalars.removeAll(keepingCapacity: true)
        }

        for scalar in input.unicodeScalars {
            if scalar == "&" {
                flushShift()
                result.append("&-")
            } else if scalar.value >= 0x20, scalar.value <= 0x7E {
                flushShift()
                result.append(Character(scalar))
            } else {
                // UTF-16 code unit(s) for this scalar (surrogate pair for
                // anything outside the BMP).
                for unit in String(scalar).utf16 {
                    pendingShiftScalars.append(unit)
                }
            }
        }
        flushShift()

        return result
    }

    /// Decodes one `&`-delimited run's BASE64 characters (already stripped
    /// of the leading `&` and any trailing `-`). Returns `nil` for any
    /// malformed sequence: an invalid character (shouldn't happen — callers
    /// only pass characters that passed the `decodeTable` lookup — but
    /// checked defensively), a byte count that isn't a multiple of 2, or
    /// bytes that don't form valid UTF-16.
    private static func decodeShiftedRun(_ chars: ArraySlice<Character>) -> String? {
        var bitBuffer: UInt32 = 0
        var bitCount = 0
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count * 6 / 8 + 1)

        for char in chars {
            guard let value = decodeTable[char] else { return nil }
            bitBuffer = (bitBuffer << 6) | UInt32(value)
            bitCount += 6
            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((bitBuffer >> UInt32(bitCount)) & 0xFF))
            }
        }

        // Any leftover bits must be zero padding, not real data — modified
        // BASE64 (like standard BASE64) never leaves a partial byte with
        // meaningful trailing bits.
        if bitCount > 0 {
            let remainder = bitBuffer & ((1 << UInt32(bitCount)) - 1)
            if remainder != 0 { return nil }
        }

        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { return nil }

        var utf16Units: [UInt16] = []
        utf16Units.reserveCapacity(bytes.count / 2)
        var index = 0
        while index < bytes.count {
            let unit = (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
            utf16Units.append(unit)
            index += 2
        }

        var decoded = ""
        decoded.reserveCapacity(utf16Units.count)
        var iterator = utf16Units.makeIterator()
        var codec = UTF16()
        while true {
            switch codec.decode(&iterator) {
            case .scalarValue(let scalar):
                decoded.unicodeScalars.append(scalar)
            case .emptyInput:
                return decoded
            case .error:
                return nil
            }
        }
    }

    private static func encodeModifiedBase64(_ bytes: [UInt8]) -> String {
        var result = ""
        result.reserveCapacity((bytes.count * 8 + 5) / 6)
        var bitBuffer: UInt32 = 0
        var bitCount = 0

        for byte in bytes {
            bitBuffer = (bitBuffer << 8) | UInt32(byte)
            bitCount += 8
            while bitCount >= 6 {
                bitCount -= 6
                let index = Int((bitBuffer >> UInt32(bitCount)) & 0x3F)
                result.append(modifiedBase64Alphabet[index])
            }
        }
        if bitCount > 0 {
            let index = Int((bitBuffer << UInt32(6 - bitCount)) & 0x3F)
            result.append(modifiedBase64Alphabet[index])
        }

        return result
    }
}
