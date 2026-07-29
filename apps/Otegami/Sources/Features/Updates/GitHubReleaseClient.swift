import Foundation
import OtegamiCore

#if os(macOS)
/// Task #158 (macOS「アップデートを確認」機能): fetches
/// `m-tkg/otegami`'s GitHub Releases and decodes them into `GitHubRelease`
/// (`OtegamiCore`). Deliberately app-layer, not `OtegamiKit` — unlike
/// `PushRelayClient` (which several targets/tests depend on), nothing else
/// in this repo needs this, and keeping it here avoids a `Package.swift`
/// edit that would collide with other in-flight work on that shared
/// manifest (see this task's own scope note). Injects `URLSession` the same
/// way `PushRelayClient` does, so tests can swap in a `URLProtocol` stub
/// instead of hitting the real network.
struct GitHubReleaseClient {
    enum ClientError: Error {
        case httpError(statusCode: Int)
        case decodingError(underlying: Error)
    }

    /// Public repo — no auth needed (spec: "認証不要 (public repo)").
    static let releasesURL = URL(string: "https://api.github.com/repos/m-tkg/otegami/releases")!

    var urlSession: URLSession = .shared

    func fetchReleases() async throws -> [GitHubRelease] {
        var request = URLRequest(url: Self.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub's REST API rejects unauthenticated requests with no
        // User-Agent header (403) — this is the one header every request
        // here must set.
        request.setValue("Otegami-macOS-UpdateChecker", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await urlSession.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw ClientError.httpError(statusCode: httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode([GitHubRelease].self, from: data)
        } catch {
            throw ClientError.decodingError(underlying: error)
        }
    }
}
#endif
