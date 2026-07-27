import Foundation

/// The outcome of one index-building request (`GooglePeopleAvatarClient
/// .fetchOtherContactsPhotoIndex(accessToken:)` /
/// `.fetchConnectionsPhotoIndex(accessToken:)`) against a single Gmail
/// account's access token. `.success` carries every (normalized email
/// address → best photo URL) pair the endpoint returned across *all* pages
/// — the caller (`GoogleProfilePhotoAvatarResolver`, `apps/Otegami/Sources/
/// Support/`) resolves individual senders by looking their address up in
/// this dictionary, rather than issuing one network request per sender.
/// `.insufficientScope` is kept apart from `.unavailable` for the same
/// reason the old per-address lookup result did: it should be remembered
/// per-account for the rest of the process (this token structurally cannot
/// produce data from this endpoint until the user reconnects with a wider
/// scope), while `.unavailable` (network error, timeout, malformed
/// response, an unexpected non-2xx status on any page) is transient and
/// must not be remembered the same way — the very next attempt might
/// succeed.
public enum GooglePeopleIndexResult: Sendable, Equatable {
    case success([String: URL])
    case insufficientScope
    case unavailable
}

/// Talks to two of the Google People API's `list` endpoints — `otherContacts`
/// (Gmail's auto-collected "people you've corresponded with but never
/// saved") and `people/me/connections` (the user's explicitly-saved
/// Contacts) — building an in-memory (email address → photo URL) index from
/// each. Apple/Linux-agnostic (plain `URLSession`, no Apple-only framework),
/// like the rest of this target — the app-layer `GoogleProfilePhotoAvatarResolver`
/// is what's Apple-only (disk caching under `Caches/`, `UIImage`/`NSImage`),
/// while this type stays trivially unit-testable with the same
/// `URLProtocol`-stub approach `GoogleOAuthClientTests` already uses.
///
/// **`.list`, not `.search`**: an earlier version of this type used
/// `otherContacts:search` (one request per sender address). Two problems
/// with that approach motivated this rewrite:
///
/// 1. `otherContacts.search` has no `sources` parameter — it can only ever
///    return `READ_SOURCE_TYPE_CONTACT`-sourced data, which is usually
///    photo-less for an auto-collected "other contact". The photo Gmail's
///    own UI shows for such a sender is typically the **PROFILE** source
///    (the sender's own Google Account profile photo, merged in), which
///    `otherContacts.list` can request via
///    `sources=READ_SOURCE_TYPE_CONTACT&sources=READ_SOURCE_TYPE_PROFILE`
///    but `.search` cannot request at all.
/// 2. A sender who *is* a saved Contact (not merely an "other contact")
///    never appears in `otherContacts` at all — reaching them needs the
///    separate `people/me/connections` endpoint (`fetchConnectionsPhotoIndex`,
///    a distinct, sensitive-adjacent scope: `contacts.readonly`).
///
/// Building a full per-account index up front (rather than searching per
/// address) also removes the need for `otherContacts.search`'s documented
/// "warm up the search index with an empty query first" workaround — `.list`
/// has no such warm-up requirement, so `GoogleProfilePhotoAvatarResolver` no
/// longer needs to track/send warm-up requests at all.
public actor GooglePeopleAvatarClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Builds the full (address → photo URL) index from `otherContacts.list`
    /// for this token, paging through every result. See this type's doc
    /// comment for why `.list` (not `.search`) and why both
    /// `READ_SOURCE_TYPE_CONTACT`/`READ_SOURCE_TYPE_PROFILE` are requested.
    public func fetchOtherContactsPhotoIndex(accessToken: String) async -> GooglePeopleIndexResult {
        await fetchPhotoIndex(
            baseURL: Self.otherContactsBaseURL,
            itemsKey: .otherContacts,
            fieldsParamName: "readMask",
            accessToken: accessToken
        )
    }

    /// Builds the full (address → photo URL) index from
    /// `people/me/connections` (the user's explicitly-saved Contacts) for
    /// this token, paging through every result. Requires the
    /// `contacts.readonly` scope (`GoogleOAuthEndpoints.scope`) — a token
    /// without it gets `.insufficientScope` here, same 401/403 convention
    /// as `fetchOtherContactsPhotoIndex`.
    public func fetchConnectionsPhotoIndex(accessToken: String) async -> GooglePeopleIndexResult {
        await fetchPhotoIndex(
            baseURL: Self.connectionsBaseURL,
            itemsKey: .connections,
            fieldsParamName: "personFields",
            accessToken: accessToken
        )
    }

    /// Downloads the raw image bytes from a URL one of the index-fetching
    /// methods returned. Kept as a separate call (rather than folded into
    /// the index fetch) so a download failure is clearly distinguishable
    /// from "no such person" at the call site, and so
    /// `GooglePeopleAvatarClientTests` can exercise URL-building/JSON-
    /// parsing without also having to stub an image byte stream. `nil` on
    /// any failure (network, non-200, empty body) — never throws, matching
    /// this type's "no exceptions" contract.
    public func downloadPhoto(url: URL) async -> Data? {
        var request = URLRequest(url: Self.sizedPhotoURL(url))
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200, !data.isEmpty
        else { return nil }
        return data
    }

    // MARK: - Paging

    private static let otherContactsBaseURL = URL(string: "https://people.googleapis.com/v1/otherContacts")!
    private static let connectionsBaseURL = URL(string: "https://people.googleapis.com/v1/people/me/connections")!

    /// Safety cap on the number of pages fetched per index build (1,000
    /// results/page × 100 pages = 100,000 people) — far beyond any realistic
    /// "other contacts"/Contacts population, this exists only to guarantee
    /// termination against a pathological/misbehaving response (e.g. a
    /// server bug that echoes back the same `nextPageToken` forever) rather
    /// than to ever actually be hit.
    private static let maxPages = 100

    /// Never throws — every failure mode (network, malformed response, HTTP
    /// error, on any page) maps to one of `GooglePeopleIndexResult`'s cases
    /// instead. A failure partway through paging discards whatever pages
    /// already succeeded rather than returning a partial index — a partial
    /// index would get disk-cached by `GoogleProfilePhotoAvatarResolver`
    /// exactly as if it were complete, silently missing entries past the
    /// failure point for the rest of that cache's TTL.
    private func fetchPhotoIndex(
        baseURL: URL,
        itemsKey: ListResponse.ItemsKey,
        fieldsParamName: String,
        accessToken: String
    ) async -> GooglePeopleIndexResult {
        var merged: [String: URL] = [:]
        var pageToken: String?
        var pagesFetched = 0

        repeat {
            guard let url = Self.pageURL(baseURL: baseURL, fieldsParamName: fieldsParamName, pageToken: pageToken) else {
                return .unavailable
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                return .unavailable
            }
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            if http.statusCode == 401 || http.statusCode == 403 {
                // Google returns 401 (no/expired token) or 403 (token valid
                // but missing this scope) for both cases; this resolver only
                // ever reaches here with a token `TokenStore` already
                // reports as currently valid, so in practice this means
                // "missing scope" — see `GoogleOAuthEndpoints.scope`'s doc
                // comment.
                return .insufficientScope
            }
            guard (200..<300).contains(http.statusCode) else { return .unavailable }

            guard let page = Self.parsePage(data, itemsKey: itemsKey) else { return .unavailable }
            // First-wins across pages for the same address — an address
            // repeated across pages (shouldn't normally happen, but the API
            // doesn't guarantee otherwise) keeps whichever photo it was
            // first paired with rather than churning on every page.
            merged.merge(page.index) { current, _ in current }
            pageToken = page.nextPageToken
            pagesFetched += 1
        } while pageToken != nil && pagesFetched < Self.maxPages

        return .success(merged)
    }

    // MARK: - URL building / response parsing (pure — exercised directly by tests)

    /// `sources` is deliberately two separate repeated query items (Google's
    /// documented format for a repeated-enum parameter), not a single
    /// comma-joined value — `URLQueryItem` appended once per value produces
    /// exactly that (`sources=READ_SOURCE_TYPE_CONTACT&sources=READ_SOURCE_TYPE_PROFILE`).
    static func pageURL(baseURL: URL, fieldsParamName: String, pageToken: String?) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: fieldsParamName, value: "emailAddresses,photos"),
            URLQueryItem(name: "sources", value: "READ_SOURCE_TYPE_CONTACT"),
            URLQueryItem(name: "sources", value: "READ_SOURCE_TYPE_PROFILE"),
            URLQueryItem(name: "pageSize", value: "1000"),
        ]
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components?.queryItems = items
        return components?.url
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

    /// Parses one page's response body into a partial (address → photo URL)
    /// index plus the next page token, or `nil` for undecodable JSON (a
    /// parse failure, not "empty page" — an empty-but-well-formed page
    /// decodes fine and just contributes nothing to the index).
    static func parsePage(_ data: Data, itemsKey: ListResponse.ItemsKey) -> (index: [String: URL], nextPageToken: String?)? {
        guard let decoded = try? JSONDecoder().decode(ListResponse.self, from: data) else { return nil }
        let entries: [PersonEntry]
        switch itemsKey {
        case .otherContacts: entries = decoded.otherContacts ?? []
        case .connections: entries = decoded.connections ?? []
        }

        var index: [String: URL] = [:]
        for entry in entries {
            guard let photoURLString = bestPhotoURLString(in: entry.photos ?? []),
                  let photoURL = URL(string: photoURLString)
            else { continue }
            for email in entry.emailAddresses ?? [] {
                guard let raw = email.value else { continue }
                let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                // First-wins within a page too, for a person listed with the
                // same address more than once (shouldn't normally happen).
                if index[normalized] == nil { index[normalized] = photoURL }
            }
        }
        return (index, decoded.nextPageToken)
    }

    /// One person's photo choice: prefer a non-default photo whose
    /// `metadata.source.type` is `PROFILE` (the person's own Google Account
    /// profile photo — what Gmail's own UI draws its sender-photo fallback
    /// from), falling back to any other non-default photo if no PROFILE-
    /// sourced one exists. A person with photos but only the placeholder
    /// silhouette (`default: true`) is treated the same as having no photo
    /// at all — showing that would be strictly worse than this app's own
    /// initials-based fallback.
    static func bestPhotoURLString(in photos: [Photo]) -> String? {
        if let profile = photos.first(where: { $0.isDefault != true && $0.url != nil && $0.metadata?.source?.type == "PROFILE" }) {
            return profile.url
        }
        return photos.first(where: { $0.isDefault != true && $0.url != nil })?.url
    }

    /// Both `otherContacts.list` and `people/me/connections`'s response
    /// bodies share this shape apart from which top-level array key they use
    /// (`otherContacts` vs `connections`) — declaring both as optional
    /// properties on one `Decodable` lets a single type parse either,
    /// disambiguated by `itemsKey` at the call site.
    struct ListResponse: Decodable {
        enum ItemsKey {
            case otherContacts
            case connections
        }

        var otherContacts: [PersonEntry]?
        var connections: [PersonEntry]?
        var nextPageToken: String?
    }

    struct PersonEntry: Decodable {
        var emailAddresses: [EmailAddress]?
        var photos: [Photo]?
    }

    struct EmailAddress: Decodable {
        var value: String?
    }

    struct Photo: Decodable {
        var url: String?
        var isDefault: Bool?
        var metadata: PhotoMetadata?

        enum CodingKeys: String, CodingKey {
            case url
            case isDefault = "default"
            case metadata
        }
    }

    struct PhotoMetadata: Decodable {
        var source: PhotoSource?
    }

    struct PhotoSource: Decodable {
        /// One of `ACCOUNT`/`PROFILE`/`DOMAIN_PROFILE`/`CONTACT`/
        /// `DOMAIN_CONTACT` per the People API's `Source.SourceType` enum —
        /// kept as the raw `String` (not decoded into a Swift enum) since
        /// `bestPhotoURLString(in:)` only ever compares it against the one
        /// literal `"PROFILE"` it cares about, and an unrecognized future
        /// value should fail that comparison harmlessly rather than fail
        /// JSON decoding of the whole response.
        var type: String?
    }
}
