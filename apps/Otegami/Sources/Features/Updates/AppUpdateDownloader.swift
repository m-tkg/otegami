import Foundation
import OtegamiCore

#if os(macOS)
/// Task #182 (macOS アプリ内アップデート、実機フィードバック「更新ボタンも
/// 置いて、自身のアップデートができるようにしてほしい」): downloads a
/// `GitHubReleaseAsset`'s `browserDownloadURL` to a caller-supplied
/// destination, reporting fractional progress and enforcing
/// `AppUpdateDownloadPolicy.isAllowedDownloadURL` on **every** hop —
/// the initial request and every redirect GitHub's CDN issues (spec:
/// "リダイレクト先も含め、想定外のホストへ落ちないこと").
///
/// Built on the structured-concurrency `URLSession.download(for:delegate:)`
/// (not the old completion-handler API) so the whole call is a single
/// `await` from `AppUpdateInstaller`'s perspective; the `delegate` parameter
/// still accepts a `URLSessionDownloadDelegate` conformer (the protocol
/// inherits from `URLSessionTaskDelegate`), which is what makes both
/// mid-flight progress (`didWriteData`) and redirect interception
/// (`willPerformHTTPRedirection`) available without falling back to the
/// legacy delegate-only download API.
struct AppUpdateDownloader {
    enum DownloadError: Error {
        case disallowedHost(URL)
        case httpError(statusCode: Int)
        case transportError(String)
    }

    var urlSession: URLSession = .shared

    /// - Parameters:
    ///   - url: `GitHubReleaseAsset.browserDownloadURL` — checked against
    ///     `AppUpdateDownloadPolicy` before any request is even made.
    ///   - destination: where the finished download is moved to. The
    ///     directory must already exist; any existing file at this path is
    ///     replaced.
    ///   - onProgress: called on an arbitrary background queue with a
    ///     fraction in `0...1` — callers that update UI state must hop back
    ///     to `@MainActor` themselves (`AboutView`'s call site does this).
    func download(from url: URL, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard AppUpdateDownloadPolicy.isAllowedDownloadURL(url) else {
            throw DownloadError.disallowedHost(url)
        }

        var request = URLRequest(url: url)
        // Matches `GitHubReleaseClient`'s own header — GitHub's edge rejects
        // requests with no User-Agent, and setting it unconditionally here
        // costs nothing on the CDN redirect target either.
        request.setValue("Otegami-macOS-UpdateInstaller", forHTTPHeaderField: "User-Agent")

        let delegate = RedirectValidatingProgressDelegate(onProgress: onProgress)
        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await urlSession.download(for: request, delegate: delegate)
        } catch let error as DownloadError {
            throw error
        } catch {
            if let disallowed = delegate.disallowedRedirectHost {
                throw DownloadError.disallowedHost(disallowed)
            }
            throw DownloadError.transportError(error.localizedDescription)
        }

        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw DownloadError.httpError(statusCode: httpResponse.statusCode)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// `NSObject`-based delegate — `URLSessionDownloadDelegate` conformance
    /// requires it, and its callbacks fire on an arbitrary URLSession-owned
    /// queue rather than any actor this app defines, hence `@unchecked
    /// Sendable` (the mutable `disallowedRedirectHost` is only ever written
    /// from those same serialized delegate callbacks, never read concurrently
    /// with a write — `URLSession` serializes delegate calls for a single
    /// task).
    private final class RedirectValidatingProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: @Sendable (Double) -> Void
        private(set) var disallowedRedirectHost: URL?

        init(onProgress: @escaping @Sendable (Double) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let newURL = request.url, AppUpdateDownloadPolicy.isAllowedDownloadURL(newURL) else {
                disallowedRedirectHost = request.url
                // Passing `nil` cancels following this redirect — the task
                // then fails with a transport error, which `download(from:
                // to:onProgress:)` above translates back into
                // `.disallowedHost` using `disallowedRedirectHost`.
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        /// Required by `URLSessionDownloadDelegate` — deliberately a no-op.
        /// The structured-concurrency `download(for:delegate:)` this struct
        /// uses already hands the finished temp file's URL back as its own
        /// return value once the whole transfer completes; this callback
        /// (the delegate-only API's own way of learning that) isn't needed
        /// alongside it.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
#endif
