import Foundation
import OtegamiRelayAPI

/// Thin HTTP client for the app<->otegami-relay wire format
/// (`OtegamiRelayAPI`'s DTOs) — everything `Support/PushSettingsStore.swift`
/// (the app layer) needs to drive the opt-in push flow: register a device,
/// rotate its APNs token, create/delete watches. `URLSession` is injected
/// (default `.shared`) so `PushRelayClientTests` can point every call at a
/// `URLProtocol` stub instead of a real server — same pattern as
/// `GoogleOAuthClient`.
///
/// Deliberately Apple-only (this target isn't in `OtegamiRelayAPI`'s
/// Linux-compatible dependency chain) even though `URLSession` itself would
/// build on Linux too — there's no reason for the *relay server* to ever
/// call its own HTTP API as a client, so keeping this a separate target
/// avoids the app's networking concerns leaking into the server's build
/// graph.
public actor PushRelayClient {
    public enum PushRelayClientError: Error, Equatable, CustomStringConvertible {
        case invalidBaseURL
        /// A non-2xx response. `body` is the decoded `RelayErrorResponse`
        /// when the server returned one (it always should, for every route
        /// this client calls), `nil` if the body couldn't be decoded as
        /// that shape.
        case http(status: Int, body: RelayErrorResponse?)
        case invalidResponse
        case network(String)

        public var description: String {
            switch self {
            case .invalidBaseURL:
                "invalid relay URL"
            case .http(let status, let body):
                if let body {
                    "relay returned \(status): \(body.message)"
                } else {
                    "relay returned \(status)"
                }
            case .invalidResponse:
                "relay returned a response that couldn't be decoded"
            case .network(let description):
                "network error: \(description)"
            }
        }
    }

    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// - Parameter registrationSecret: Task #171 — a *shared operator
    ///   secret* (distinct from the per-device `deviceSecret` every other
    ///   call here uses), sent only when the relay's operator configured
    ///   `RELAY_DEVICE_REGISTRATION_SECRET` (see
    ///   `DeviceRoutes.authorizeRegistration` on the server). `nil` (the
    ///   default) omits the `Authorization` header entirely, which is what
    ///   keeps this call working unchanged against every relay that hasn't
    ///   set that env var — `authorizeRegistration` only checks the header
    ///   when the operator opted in.
    public func registerDevice(
        baseURL: URL,
        apnsToken: String,
        environment: RegisterDeviceRequest.Environment,
        registrationSecret: String? = nil
    ) async throws -> RegisterDeviceResponse {
        try await send(
            baseURL: baseURL,
            path: "v1/devices",
            method: "POST",
            body: RegisterDeviceRequest(apnsToken: apnsToken, environment: environment),
            bearerToken: registrationSecret,
            expectedStatus: 201
        )
    }

    public func updateDeviceToken(
        baseURL: URL,
        deviceId: String,
        deviceSecret: String,
        apnsToken: String,
        environment: RegisterDeviceRequest.Environment
    ) async throws {
        try await sendNoContent(
            baseURL: baseURL,
            path: "v1/devices/\(deviceId)/token",
            method: "PUT",
            body: UpdateDeviceTokenRequest(apnsToken: apnsToken, environment: environment),
            bearerToken: deviceSecret,
            expectedStatus: 204
        )
    }

    public func createWatch(
        baseURL: URL,
        deviceSecret: String,
        request: CreateWatchRequest
    ) async throws -> WatchResponse {
        try await send(
            baseURL: baseURL,
            path: "v1/watches",
            method: "POST",
            body: request,
            bearerToken: deviceSecret,
            expectedStatus: 201
        )
    }

    /// `GET /v1/watches` — every watch this device currently owns on the
    /// relay, credential-free. `AppEnvironment.reconcilePushWatchesIfNeeded()`
    /// is the one caller: it diffs this against the app's local accounts
    /// (via `WatchReconciler.plan`) to delete orphaned watches and
    /// re-register missing ones.
    public func listWatches(baseURL: URL, deviceSecret: String) async throws -> [WatchSummary] {
        let response: ListWatchesResponse = try await send(
            baseURL: baseURL,
            path: "v1/watches",
            method: "GET",
            body: Optional<String>.none,
            bearerToken: deviceSecret,
            expectedStatus: 200
        )
        return response.watches
    }

    public func deleteWatch(baseURL: URL, deviceSecret: String, watchId: String) async throws {
        try await sendNoContent(
            baseURL: baseURL,
            path: "v1/watches/\(watchId)",
            method: "DELETE",
            body: Optional<String>.none,
            bearerToken: deviceSecret,
            expectedStatus: 204
        )
    }

    /// Bounds every `fetchMessagePreviews` call — Phase 3 (NSE のリレー先読み
    /// 統合): `NotificationService.enrich(payload:)` calls this from inside
    /// its own 5 second notification-display budget, so this HTTP round
    /// trip must never be the thing that blows through it. Set on the
    /// individual `URLRequest` (`URLRequest.timeoutInterval`), not the
    /// `URLSession`'s configuration, so it applies regardless of which
    /// session a caller injected at `init` — the app's long-lived
    /// `.shared`-backed instance and a short-lived Extension-side instance
    /// both get the same bound on this one call without needing their own
    /// dedicated `URLSessionConfiguration`.
    public static let messagePreviewFetchTimeout: TimeInterval = 5

    /// `GET /v1/messages` (`RELAY_CONTENT_PREVIEW`, opt-in, Phase 2/3) —
    /// up to the newest 10 decrypted content previews the relay has cached
    /// for this watch, uid descending, each `uid > sinceUid`.
    /// `NotificationService.enrich(payload:)` is the one caller: it uses
    /// this to show a body preview in the notification itself without
    /// waiting for its own (heavier) IMAP-based sync to complete.
    ///
    /// A 404 means either this relay doesn't have `RELAY_CONTENT_PREVIEW`
    /// enabled at all, or this device has no watch for `accountId` — the
    /// two are indistinguishable by design (`message_routes.go`'s own doc
    /// comment: the response either way is "nothing to show"), surfaced
    /// here as an ordinary `PushRelayClientError.http(status: 404, body:)`
    /// so a caller can pattern-match on that status to treat it as "the
    /// feature isn't available right now" rather than a genuine failure.
    public func fetchMessagePreviews(
        baseURL: URL,
        deviceSecret: String,
        accountId: String,
        sinceUid: Int
    ) async throws -> [MessagePreview] {
        try await send(
            baseURL: baseURL,
            path: "v1/messages",
            method: "GET",
            body: Optional<String>.none,
            bearerToken: deviceSecret,
            expectedStatus: 200,
            queryItems: [
                URLQueryItem(name: "accountId", value: accountId),
                URLQueryItem(name: "sinceUid", value: String(sinceUid)),
            ],
            timeout: Self.messagePreviewFetchTimeout
        )
    }

    // MARK: - Plumbing

    private static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func send<Body: Encodable, Response: Decodable>(
        baseURL: URL,
        path: String,
        method: String,
        body: Body?,
        bearerToken: String?,
        expectedStatus: Int,
        queryItems: [URLQueryItem] = [],
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        let (data, _) = try await performRequest(
            baseURL: baseURL,
            path: path,
            method: method,
            body: body,
            bearerToken: bearerToken,
            expectedStatus: expectedStatus,
            queryItems: queryItems,
            timeout: timeout
        )
        guard let decoded = try? Self.jsonDecoder.decode(Response.self, from: data) else {
            throw PushRelayClientError.invalidResponse
        }
        return decoded
    }

    /// For routes that respond 204 No Content — no response body to decode.
    private func sendNoContent<Body: Encodable>(
        baseURL: URL,
        path: String,
        method: String,
        body: Body?,
        bearerToken: String?,
        expectedStatus: Int
    ) async throws {
        _ = try await performRequest(
            baseURL: baseURL,
            path: path,
            method: method,
            body: body,
            bearerToken: bearerToken,
            expectedStatus: expectedStatus,
            queryItems: [],
            timeout: nil
        )
    }

    private func performRequest<Body: Encodable>(
        baseURL: URL,
        path: String,
        method: String,
        body: Body?,
        bearerToken: String?,
        expectedStatus: Int,
        queryItems: [URLQueryItem] = [],
        timeout: TimeInterval? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw PushRelayClientError.invalidBaseURL
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = "\(basePath)/\(path)"
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw PushRelayClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout {
            request.timeoutInterval = timeout
        }
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let error as PushRelayClientError {
            throw error
        } catch {
            throw PushRelayClientError.network("\(error)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw PushRelayClientError.invalidResponse
        }
        guard http.statusCode == expectedStatus else {
            let errorBody = try? Self.jsonDecoder.decode(RelayErrorResponse.self, from: data)
            throw PushRelayClientError.http(status: http.statusCode, body: errorBody)
        }
        return (data, http)
    }
}
