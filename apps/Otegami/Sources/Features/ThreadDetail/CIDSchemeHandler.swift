import Foundation
import WebKit
import GRDB
import MailTransport
import OtegamiStore
import SyncEngine

/// Serves `otegami-cid://<contentId>` requests (the rewritten form of an
/// HTML body's `src="cid:<contentId>"`, produced by `CIDURLRewriter`) from
/// the `attachment` table — downloading the part on demand via
/// `SyncCoordinator.fetchAttachment` if it hasn't been fetched yet (plan:
/// "未取得の inline 画像は表示時に自動取得"), then serving the bytes already on
/// disk otherwise. Registered on the web view's `WKWebViewConfiguration` in
/// `HTMLWebViewRepresentable`'s `makeUIView`/`makeNSView`.
///
/// `@MainActor` throughout: `WKURLSchemeHandler`'s methods are documented
/// to always be called on the main thread, and every dependency this touches
/// (`AppEnvironment`, GRDB's `dbWriter`) is happiest driven from one
/// consistent isolation rather than hopping actors per request.
@MainActor
final class CIDSchemeHandler: NSObject, WKURLSchemeHandler {
    private var context: CIDResolutionContext
    /// One resolution `Task` per in-flight `WKURLSchemeTask`, keyed by its
    /// identity — `webView(_:stop:)` cancels the matching entry so a
    /// `didReceive`/`didFinish` call can never land on a task WebKit has
    /// already torn down (which WebKit logs as an error and — on some
    /// versions — treats as a hard failure of the whole load).
    private var inFlightTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(context: CIDResolutionContext) {
        self.context = context
    }

    /// Keeps `mailboxPath` (and, in principle, the other fields) current
    /// across `HTMLWebViewRepresentable.update{UI,NS}View` calls — see
    /// `HTMLWebViewCoordinator.cidHandler`'s doc comment for why this
    /// matters even though `accountId`/`messageId` never actually change
    /// for a mounted `MessageView` instance in practice.
    func updateContext(_ context: CIDResolutionContext) {
        self.context = context
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        let contentId = Self.contentId(from: urlSchemeTask.request.url)

        inFlightTasks[key] = Task { [weak self] in
            guard let self else { return }
            defer { self.inFlightTasks.removeValue(forKey: key) }

            do {
                guard let contentId else {
                    throw CIDResolutionError.malformedURL
                }
                let (data, mimeType) = try await self.resolve(contentId: contentId)
                guard !Task.isCancelled else { return }
                guard let url = urlSchemeTask.request.url else { return }
                let response = URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        inFlightTasks[key]?.cancel()
        inFlightTasks.removeValue(forKey: key)
    }

    /// `otegami-cid://<contentId>` — `URL.host` is what `CIDURLRewriter`'s
    /// `otegami-cid://$3` template lands `contentId` in (the part right
    /// after `scheme://`), so a plain host read is enough; no path/query
    /// parsing needed.
    private static func contentId(from url: URL?) -> String? {
        url?.host
    }

    enum CIDResolutionError: Error {
        case malformedURL
        case notFound
        case dataUnavailable
    }

    private func resolve(contentId: String) async throws -> (Data, String) {
        guard let attachment = try await findAttachment(contentId: contentId) else {
            throw CIDResolutionError.notFound
        }

        if let localPath = attachment.localPath, let data = FileManager.default.contents(atPath: localPath) {
            return (data, Self.mimeTypeString(attachment))
        }

        let messageId = context.messageId
        let database = context.environment.database
        guard let mailboxPath = context.mailboxPath,
              let account = context.environment.accounts.first(where: { $0.id == context.accountId }),
              let message = try await database.dbWriter.read({ db in
                  try MessageRecord.fetchOne(db, key: messageId)
              })
        else {
            throw CIDResolutionError.dataUnavailable
        }

        let auth = try await context.environment.auth(for: account)
        let updated = try await context.environment.syncCoordinator.fetchAttachment(
            attachment, messageUID: message.uid, mailboxPath: mailboxPath, account: account, auth: auth
        )
        guard let localPath = updated.localPath, let data = FileManager.default.contents(atPath: localPath) else {
            throw CIDResolutionError.dataUnavailable
        }
        return (data, Self.mimeTypeString(updated))
    }

    /// Attachment `Content-ID` headers are matched with (and without) the
    /// RFC 2392 angle brackets stripped from both sides — the attachment
    /// table stores whatever MailCore2's parser reported (M2's
    /// `BodyFetcherTests` fixtures use bracket-less values, matching this
    /// app's own observed data), but a bracket mismatch between what a
    /// server sends and what an HTML `src="cid:...">` references is a
    /// plausible enough interop wrinkle to guard against cheaply here
    /// rather than ever showing a broken inline image over it.
    private func findAttachment(contentId: String) async throws -> AttachmentRecord? {
        let stripped = contentId.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let messageId = context.messageId
        let database = context.environment.database
        return try await database.dbWriter.read { db in
            try AttachmentRecord
                .filter(Column("messageId") == messageId)
                .filter(Column("contentId") == contentId || Column("contentId") == stripped)
                .fetchOne(db)
        }
    }

    private static func mimeTypeString(_ attachment: AttachmentRecord) -> String {
        "\(attachment.mimeType)/\(attachment.mimeSubtype)"
    }
}
