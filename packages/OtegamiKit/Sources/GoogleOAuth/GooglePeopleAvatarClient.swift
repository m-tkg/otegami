import Foundation

/// The outcome of one `GooglePeopleAvatarClient.lookupPhoto(accessToken:address:)`
/// attempt against a single Gmail account's access token.
///
/// Deliberately distinguishes `.notFound` (a well-formed response that just
/// didn't match `address`) from `.insufficientScope`/`.unavailable` — the
/// app-layer caller (`GoogleProfilePhotoAvatarResolver`, `apps/Otegami/
/// Sources/Support/`) needs all three kept apart: `.notFound` is safe to
/// negative-cache (asking again won't change the answer until the person's
/// Google contact changes), `.insufficientScope` should be remembered
/// per-account for the rest of the process so it isn't retried on every
/// avatar resolution, and `.unavailable` (network error, timeout, an
/// unexpected non-2xx status) is transient and must not be cached either
/// way.
public enum GooglePeopleAvatarLookupResult: Sendable, Equatable {
    case found(photoURL: URL)
    case notFound
    case insufficientScope
    case unavailable
}

/// Talks to the Google People API's `otherContacts.search` endpoint for one
/// (access token, sender address) pair. Apple/Linux-agnostic (plain
/// `URLSession`, no Apple-only framework), like the rest of this target —
/// the app-layer `GoogleProfilePhotoAvatarResolver` is what's Apple-only
/// (disk caching under `Caches/`, `UIImage`/`NSImage`), while this type
/// stays trivially unit-testable with the same `URLProtocol`-stub approach
/// `GoogleOAuthClientTests` already uses.
///
/// **`otherContacts.search` only, not also `people.searchContacts`**: the
/// People API also has `people.searchContacts`, which searches a user's
/// *explicit*, saved Contacts. `otherContacts` — Gmail's auto-collected
/// "people you've corresponded with but never saved" — is the population
/// Gmail's own web/mobile clients draw their sender-photo fallback from, and
/// is exactly the gap this resolver exists to close (a Gravatar-less sender
/// otegami has no saved Contact for). Adding a second API call to also query
/// `searchContacts` would double the request count (and thus the scope's
/// sensitive-data exposure) for a population that's already covered by a
/// device's on-device `ContactPhotoResolver` (macOS/iOS Contacts sync from
/// the same Google Contacts, when the user has that sync configured) — the
/// marginal benefit didn't seem to justify the added cost/complexity, so
/// this was decided against rather than left unimplemented by oversight.
public actor GooglePeopleAvatarClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// One search attempt for `address` using `accessToken`. Never throws —
    /// every failure mode (network, malformed response, HTTP error) maps to
    /// one of `GooglePeopleAvatarLookupResult`'s cases instead, so the
    /// caller never needs a `try`/`catch` around this.
    public func lookupPhoto(accessToken: String, address: String) async -> GooglePeopleAvatarLookupResult {
        guard let url = Self.searchURL(for: address) else { return .unavailable }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .unavailable
        }
        guard let http = response as? HTTPURLResponse else { return .unavailable }
        if http.statusCode == 401 || http.statusCode == 403 {
            // Google returns 401 (no/expired token) or 403 (token valid but
            // missing this scope) for both cases; this resolver only ever
            // reaches here with a token `TokenStore` already reports as
            // currently valid, so in practice this means "missing scope" —
            // see `GoogleOAuthEndpoints.scope`'s doc comment.
            return .insufficientScope
        }
        guard (200..<300).contains(http.statusCode) else { return .unavailable }

        guard let photoURLString = Self.matchingPhotoURLString(in: data, address: address),
              let photoURL = URL(string: photoURLString)
        else {
            return .notFound
        }
        return .found(photoURL: photoURL)
    }

    /// Google's official guidance for `otherContacts.search`: the very
    /// first search against a given token can come back empty even for a
    /// person who genuinely is in "other contacts", because the search
    /// index isn't warmed up yet — an empty-query request beforehand
    /// primes it. This method exists solely to send that warmup request;
    /// its result (success, error, empty body, anything) is deliberately
    /// discarded — a warmup failure is not evidence of anything (not
    /// "insufficient scope", not "no other contacts exist") and must never
    /// stop the caller from still attempting the real `lookupPhoto` search
    /// right after. Never throws, matching this type's "no exceptions"
    /// contract.
    public func warmupSearchIndex(accessToken: String) async {
        _ = await lookupPhoto(accessToken: accessToken, address: "")
    }

    /// Downloads the raw image bytes from a URL `lookupPhoto` returned.
    /// Kept as a separate call (rather than folded into `lookupPhoto`) so a
    /// download failure is clearly distinguishable from "no such person" at
    /// the call site, and so `GooglePeopleAvatarClientTests` can exercise
    /// URL-building/JSON-parsing without also having to stub an image byte
    /// stream. `nil` on any failure (network, non-200, empty body) — never
    /// throws, matching `lookupPhoto`'s "no exceptions" contract.
    public func downloadPhoto(url: URL) async -> Data? {
        var request = URLRequest(url: Self.sizedPhotoURL(url))
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200, !data.isEmpty
        else { return nil }
        return data
    }

    // MARK: - URL building / response parsing (pure — exercised directly by tests)

    /// `otherContacts:search?readMask=photos,emailAddresses&query=<address>`
    /// — a `GET` request per the People API's documented shape.
    static func searchURL(for address: String) -> URL? {
        var components = URLComponents(string: "https://people.googleapis.com/v1/otherContacts:search")
        components?.queryItems = [
            URLQueryItem(name: "readMask", value: "photos,emailAddresses"),
            URLQueryItem(name: "query", value: address),
        ]
        return components?.url
    }

    /// The first non-default photo URL belonging to a result whose
    /// `emailAddresses` contains `address` (case-insensitive, matching
    /// `GravatarAvatarResolver.normalize`'s trim+lowercase convention). A
    /// person with photos but only the placeholder silhouette (`default:
    /// true`) is treated the same as having no photo at all — showing that
    /// would be strictly worse than this app's own initials-based
    /// fallback. `nil` for a well-formed response with no such match
    /// (`.notFound`, not a parse failure) as well as for genuinely
    /// undecodable JSON (`.notFound` too — `lookupPhoto` can't tell the two
    /// apart from this return value alone, and both mean "nothing to show
    /// from this attempt").
    static func matchingPhotoURLString(in data: Data, address: String) -> String? {
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return nil }
        let normalizedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for result in decoded.results ?? [] {
            guard let person = result.person else { continue }
            let emails = (person.emailAddresses ?? []).compactMap { $0.value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard emails.contains(normalizedAddress) else { continue }
            if let photo = (person.photos ?? []).first(where: { $0.isDefault != true && $0.url != nil }) {
                return photo.url
            }
        }
        return nil
    }

    /// Google's profile-photo hosting (`lh3.googleusercontent.com` and
    /// similar) accepts a `=s<N>` size suffix to have the CDN itself
    /// downscale the image instead of the client fetching a full-resolution
    /// original just to shrink it for a ~30pt avatar circle — the same
    /// motivation as `GravatarAvatarResolver.gravatarURL(for:)`'s `s=160`
    /// query parameter, just a different API's convention for it. Only
    /// appended when the URL doesn't already look sized, so a URL that
    /// already carries its own size suffix (or belongs to a host that
    /// doesn't support this convention, where the suffix is harmlessly
    /// ignored by the server or 404s and just falls back to `.unavailable`
    /// for that one download) isn't double-modified.
    static func sizedPhotoURL(_ url: URL) -> URL {
        let string = url.absoluteString
        guard !string.contains("=s") else { return url }
        return URL(string: string + "=s160") ?? url
    }

    private struct SearchResponse: Decodable {
        var results: [SearchResult]?
    }

    private struct SearchResult: Decodable {
        var person: Person?
    }

    private struct Person: Decodable {
        var emailAddresses: [EmailAddress]?
        var photos: [Photo]?
    }

    private struct EmailAddress: Decodable {
        var value: String?
    }

    private struct Photo: Decodable {
        var url: String?
        var isDefault: Bool?

        enum CodingKeys: String, CodingKey {
            case url
            case isDefault = "default"
        }
    }
}
