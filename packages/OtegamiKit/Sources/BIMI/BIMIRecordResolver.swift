import Foundation

/// Task #42, point 4「BIMI 対応」: resolves a sender domain's BIMI (Brand
/// Indicators for Message Identification) logo URL, the same mechanism
/// Gmail's own UI uses to show a verified sender's brand logo instead of an
/// initials avatar. Apple-only, `dnssd`-based DNS TXT lookup was considered
/// and rejected for `CompanyLogoAvatarResolver`'s earlier favicon-only phase
/// (see that type's doc comment for the full reasoning) — this batch's
/// instructions explicitly call for DNS-over-HTTPS instead
/// (`https://dns.google/resolve`), a deliberate reversal of that earlier
/// decision's "no third-party DoH — privacy" stance, made knowingly by this
/// batch's author. `docs/design-system.md`'s BIMI section documents this
/// reversal.
///
/// **Linux-compatible, no Apple-only dependency** (plain `URLSession`, JSON
/// decoding) — like `GoogleOAuth`'s HTTP client, this makes the DNS lookup
/// and BIMI-record parsing trivially unit-testable with the same
/// `URLProtocol`-stub approach the rest of this package uses. The one part
/// of BIMI support that genuinely needs an Apple-only API — rasterizing the
/// fetched SVG into pixel data — deliberately lives in the app layer
/// (`apps/Otegami/Sources/Support/BIMISVGRenderer.swift`), consuming
/// `BIMISVGParser`'s pure `BIMIVectorImage` model instead of `CoreGraphics`
/// directly here.
public enum BIMILookupResult: Sendable, Equatable {
    /// A `default._bimi.<domain>` TXT record was found and successfully
    /// parsed into a `v=BIMI1;` tag set with a non-empty `l=` (logo) URL.
    case found(URL)
    /// The DNS query itself succeeded (Google's DoH resolver answered) but
    /// there's no usable BIMI record for this domain — NXDOMAIN, no TXT
    /// records at all, a TXT record that isn't `v=BIMI1;`-tagged, or a
    /// `v=BIMI1;` record with no (or a non-https) `l=` value. Distinct from
    /// `.unavailable` so a caller can treat this as "definitively no BIMI
    /// logo, fall through to favicon" rather than "try again later".
    case notFound
    /// The DoH request itself failed (network error, timeout, malformed
    /// JSON, unexpected HTTP status) — transient, unlike `.notFound`.
    case unavailable
}

public struct BIMIRecordClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Looks up `default._bimi.<domain>` via Google's public DNS-over-HTTPS
    /// JSON API and returns the logo URL from any `v=BIMI1;` TXT record
    /// found. Never throws — every failure mode maps to `.unavailable`
    /// (matching this package's other network clients' "no exceptions"
    /// contract, e.g. `GooglePeopleAvatarClient`).
    public func resolveLogoURL(domain: String) async -> BIMILookupResult {
        guard let url = Self.queryURL(domain: domain) else { return .unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        // Google's DoH JSON API requires this Accept header (it also serves
        // raw DNS wire format by default without it).
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .unavailable
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return .unavailable
        }
        guard let decoded = try? JSONDecoder().decode(DoHResponse.self, from: data) else {
            return .unavailable
        }
        // `Status` follows the standard DNS RCODE values — 0 is NOERROR.
        // Anything else (2 = SERVFAIL, 3 = NXDOMAIN, ...) means "no such
        // record", which is `.notFound` here (NXDOMAIN for a domain with no
        // BIMI record at all is the overwhelmingly common case), not a
        // transient failure.
        guard decoded.status == 0 else { return .notFound }

        for answer in decoded.answer ?? [] {
            guard let raw = answer.data, let logoURL = Self.logoURL(fromTXTRecordData: raw) else { continue }
            return .found(logoURL)
        }
        return .notFound
    }

    // MARK: - Pure parsing (exercised directly by tests)

    static func queryURL(domain: String) -> URL? {
        guard !domain.isEmpty else { return nil }
        var components = URLComponents(string: "https://dns.google/resolve")
        components?.queryItems = [
            URLQueryItem(name: "name", value: "default._bimi.\(domain)"),
            URLQueryItem(name: "type", value: "TXT"),
        ]
        return components?.url
    }

    /// Turns one DoH `Answer.data` string (the TXT record's value, exactly
    /// as Google's resolver echoes it back — one or more `"..."`-quoted
    /// segments, since DNS TXT records are a *list* of character-strings,
    /// not a single string) into a logo URL, or `nil` if it isn't a
    /// `v=BIMI1;` record or has no usable `l=` tag.
    ///
    /// **Reassembly, not naive space-joining**: a long TXT value gets split
    /// across multiple quoted segments at (traditionally) 255-byte
    /// boundaries, which can land mid-URL. Concatenating each quoted
    /// segment's *contents* directly (no separator) reverses that split
    /// correctly; blindly replacing `"` with nothing and leaving whatever
    /// whitespace separated the quoted segments in the raw string would
    /// silently corrupt a URL that happened to split there.
    static func logoURL(fromTXTRecordData raw: String) -> URL? {
        let reassembled = reassembleQuotedSegments(raw)
        // BIMI (RFC-in-progress) requires the record to open with exactly
        // `v=BIMI1;` — case-sensitive per the spec, but this accepts
        // leading/trailing whitespace around the whole record since some
        // resolvers/zones are inconsistent about that.
        let trimmed = reassembled.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("v=BIMI1;") else { return nil }

        for tag in trimmed.split(separator: ";") {
            let parts = tag.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "l" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: value), url.scheme?.lowercased() == "https" else { continue }
            return url
        }
        return nil
    }

    /// See `logoURL(fromTXTRecordData:)`'s doc comment. If `raw` contains no
    /// `"`-quoted segments at all (a resolver that already unquoted a
    /// single-segment value), returns it unchanged.
    private static func reassembleQuotedSegments(_ raw: String) -> String {
        var segments: [Substring] = []
        let current = raw[raw.startIndex...]
        var insideQuotes = false
        var start = current.startIndex
        var index = current.startIndex
        while index < current.endIndex {
            if current[index] == "\"" {
                if insideQuotes {
                    segments.append(current[start..<index])
                } else {
                    start = current.index(after: index)
                }
                insideQuotes.toggle()
            }
            index = current.index(after: index)
        }
        guard !segments.isEmpty else { return raw }
        return segments.joined()
    }

    struct DoHResponse: Decodable {
        var status: Int?
        var answer: [Answer]?

        enum CodingKeys: String, CodingKey {
            case status = "Status"
            case answer = "Answer"
        }
    }

    struct Answer: Decodable {
        var data: String?

        enum CodingKeys: String, CodingKey {
            case data = "data"
        }
    }
}
