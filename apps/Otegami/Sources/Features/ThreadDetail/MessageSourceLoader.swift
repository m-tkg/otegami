import Foundation
import OtegamiCore
import OtegamiStore
import SyncEngine
import os

/// Task #103 ("ソースを表示" — 表示崩れメールの eml を受け渡す調査経路):
/// owns every piece of state `MessageSourceView` shows — the raw RFC822
/// source's on-disk cache/fetch, display truncation, and load/retry/error
/// — as a plain reference type held in the sheet's own `@State`. Mirrors
/// `CalendarInviteLoader` (Task #94) deliberately: an `@Observable` class
/// whose `load(...)` kicks off a plain `Task { }` (not a SwiftUI `.task`
/// modifier) rather than doing the fetch inline in an `async` method a
/// view calls directly — see that type's doc comment for the exact
/// "conditional child view remounts mid-flight, its `.task` gets
/// cancelled, no card ever appears" failure mode this sidesteps. A `Task`
/// created this way isn't tied to any view's lifecycle at all, so a caller
/// re-invoking `load(...)` for a `messageId` already loaded/loading is a
/// deliberate no-op (`loadedMessageId` below) rather than losing progress.
@MainActor
@Observable
final class MessageSourceLoader {
    enum LoadState {
        case idle
        case loading
        case loaded(DisplaySource)
        case failed(String)
    }

    /// What `MessageSourceView` actually renders — the (possibly
    /// truncated) preview text plus a ready-to-share file URL, both
    /// resolved once here rather than recomputed on every `body`
    /// evaluation.
    struct DisplaySource {
        /// The cached raw-source file (`MessageSourceFetcher`'s own
        /// deterministic per-message path) — always the *full* message,
        /// regardless of `isTruncated`.
        let fileURL: URL
        /// A copy of `fileURL` under `FileManager.temporaryDirectory`
        /// named from the message's subject (`MessageSourceFilename
        /// .sanitized`) — what `ShareLink` actually offers, so the share
        /// sheet suggests a sensible `.eml` filename instead of
        /// `fileURL`'s own `<messageId>.eml`. Falls back to `fileURL`
        /// itself if the copy couldn't be made (`prepareShareFile`'s doc
        /// comment) — a less friendly filename beats no share option.
        let shareURL: URL
        let previewText: String
        let isTruncated: Bool
        let totalByteCount: Int
    }

    /// 512KB — generous enough to show a real message's headers plus a
    /// good chunk of body (the "表示崩れメールの eml を受け渡す調査経路"
    /// this feature exists for), small enough that even a pathological
    /// multi-MB message never makes this view lay out an enormous `Text`
    /// at once. Only the in-view *preview* is capped — the cache file and
    /// `ShareLink` export are always the full message.
    static let previewByteLimit = 512 * 1024

    private(set) var state: LoadState = .idle

    @ObservationIgnored private var loadedMessageId: Int64?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.mtkg.otegami", category: "MessageSource")

    /// Downloads (if not already cached — see `MessageSourceFetcher`'s own
    /// doc comment) and renders `messageId`'s raw source. A no-op if
    /// `messageId` is already loaded or currently loading.
    ///
    /// Deliberately takes only `messageId`/`accountId`/`subject` — not the
    /// message's own `uid`/owning mailbox path — so `MessageSourceView`'s
    /// caller (`ThreadDetailView.sourceSheet`) doesn't need its own
    /// separate async lookup for those (unlike `infoSheet`'s
    /// `loadInfoDetails(for:)`) just to open this sheet. `performLoad`
    /// below resolves them itself, straight from `environment.database`,
    /// and only when actually needed (a cache miss — see its doc comment).
    func load(messageId: Int64, accountId: String, subject: String?, environment: AppEnvironment) {
        guard loadedMessageId != messageId else { return }
        loadedMessageId = messageId
        loadTask?.cancel()
        state = .loading
        loadTask = Task { [weak self] in
            await self?.performLoad(messageId: messageId, accountId: accountId, subject: subject, environment: environment)
        }
    }

    /// The error state's "再試行" button: forgets that this message was
    /// already attempted, then calls `load` again.
    func retry(messageId: Int64, accountId: String, subject: String?, environment: AppEnvironment) {
        loadedMessageId = nil
        load(messageId: messageId, accountId: accountId, subject: subject, environment: environment)
    }

    private func performLoad(messageId: Int64, accountId: String, subject: String?, environment: AppEnvironment) async {
        let fileURL: URL
        if let cached = MessageSourceFetcher.cachedURL(accountId: accountId, messageId: messageId) {
            fileURL = cached
        } else {
            guard let account = environment.accounts.first(where: { $0.id == accountId }) else {
                state = .failed(String(localized: "アカウントが見つかりません。"))
                return
            }
            guard let location = await Self.resolveMessageLocation(messageId: messageId, environment: environment) else {
                state = .failed(String(localized: "ソースを読み込めませんでした。"))
                return
            }
            do {
                let auth = try await environment.auth(for: account)
                fileURL = try await environment.syncCoordinator.fetchRawSource(
                    messageId: messageId, messageUID: location.uid, mailboxPath: location.mailboxPath,
                    account: account, auth: auth
                )
            } catch {
                Self.logger.error("fetch: messageId=\(messageId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                state = .failed(String(localized: "ソースを読み込めませんでした。オフラインの場合は接続を確認して再試行してください。"))
                return
            }
        }

        guard let display = Self.makeDisplaySource(fileURL: fileURL, subject: subject) else {
            Self.logger.error("read: messageId=\(messageId, privacy: .public) cached file unreadable")
            state = .failed(String(localized: "ソースを読み込めませんでした。"))
            return
        }
        state = .loaded(display)
    }

    /// This message's own IMAP `uid` plus its owning mailbox's `path` —
    /// only resolved on a cache miss (`performLoad` above), since a cache
    /// hit needs neither. Read straight from `environment.database` rather
    /// than requiring the caller to already have both in scope.
    private static func resolveMessageLocation(
        messageId: Int64, environment: AppEnvironment
    ) async -> (uid: Int64, mailboxPath: String)? {
        try? await environment.database.dbWriter.read { db in
            guard let message = try MessageRecord.fetchOne(db, key: messageId),
                  let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId)
            else { return nil }
            return (message.uid, mailbox.path)
        }
    }

    private static func makeDisplaySource(fileURL: URL, subject: String?) -> DisplaySource? {
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else { return nil }
        defer { try? handle.close() }
        guard let totalByteCount = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: 0)
        let readLength = min(Int(totalByteCount), previewByteLimit)
        guard let chunk = try? handle.read(upToCount: readLength) else { return nil }
        let previewText = String(decoding: chunk, as: UTF8.self)
        let shareURL = prepareShareFile(sourceURL: fileURL, subject: subject) ?? fileURL
        return DisplaySource(
            fileURL: fileURL,
            shareURL: shareURL,
            previewText: previewText,
            isTruncated: Int(totalByteCount) > readLength,
            totalByteCount: Int(totalByteCount)
        )
    }

    /// Copies the cached raw source to `FileManager.temporaryDirectory`
    /// under a subject-derived filename so `ShareLink`'s share sheet
    /// offers a friendlier name than the cache's own `<messageId>.eml`.
    /// Best-effort: a failed copy (disk full, ...) just falls back to
    /// sharing `fileURL` directly (`makeDisplaySource` above) rather than
    /// failing the whole load over what's purely a filename nicety.
    private static func prepareShareFile(sourceURL: URL, subject: String?) -> URL? {
        let filename = MessageSourceFilename.sanitized(subject: subject)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
