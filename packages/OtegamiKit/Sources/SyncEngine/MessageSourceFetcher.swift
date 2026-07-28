import Foundation
import MailTransport

/// Task #103 ("ソースを表示" — 生 RFC822 ソース表示 + `.eml` シェア): on-
/// demand raw-message fetch via an already-connected/`select`ed
/// `IMAPSessionProtocol`, cached at a deterministic per-message path under
/// `<Application Support>/otegami/MessageSource/<accountId>/<messageId>.eml`
/// so a second view of the same message never re-fetches over the network
/// — mirrors `AttachmentFetcher`'s "check disk first, only touch the
/// network on a genuine cache miss" shape and its `storageURL` nesting
/// convention (one `otegami/` folder for every piece of this app's on-disk
/// state, rather than a new top-level Application Support directory).
///
/// Unlike `AttachmentFetcher`, this actor has no `AppDatabase` dependency
/// and persists nothing to a database column — the cache file's own
/// existence on disk *is* the cache. There is no raw-source column on
/// `MessageRecord`, and adding one purely to remember "was this ever
/// fetched" would just duplicate what `FileManager.fileExists` already
/// answers directly against the same deterministic path this actor
/// computes to fetch in the first place.
///
/// Reuses `IMAPSessionProtocol.fetchMessageBody(mailboxPath:uid:partId:)`
/// with `partId: nil` rather than adding a new transport-level method:
/// that overload's own doc comment already documents "the whole message's
/// raw RFC 822 bytes when partId is nil", and `MailCoreIMAPSession`'s
/// implementation of it bridges to mailcore2's `fetchMessageOperation` —
/// confirmed against the pinned mailcore2 revision's `MCIMAPSession.cpp`
/// (`fetch_rfc822` building its `FETCH` via
/// `mailimap_fetch_att_new_body_peek_section`) that this issues `UID FETCH
/// BODY.PEEK[]`, the `.PEEK` variant that never sets `\Seen` — exactly this
/// task's "IMAP の UID FETCH BODY.PEEK[] (\Seen を立てない) でオンデマンド
/// 取得する" requirement, with no new protocol surface needed.
public actor MessageSourceFetcher {
    public init() {}

    /// Downloads (if not already cached) and persists `messageId`'s raw
    /// RFC822 source, returning the local file's `URL`. A no-op network
    /// fetch — just returns the existing cached `URL` — if a previous call
    /// already downloaded this message's source and the file still exists
    /// on disk.
    @discardableResult
    public func fetchAndStore(
        messageId: Int64,
        accountId: String,
        messageUID: Int64,
        mailboxPath: String,
        session: any IMAPSessionProtocol
    ) async throws -> URL {
        let destination = try Self.storageURL(accountId: accountId, messageId: messageId)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        let data = try await session.fetchMessageBody(mailboxPath: mailboxPath, uid: UInt32(messageUID), partId: nil)

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// The cached file's `URL` if a previous `fetchAndStore` already
    /// downloaded it, `nil` if never fetched (or the file was somehow
    /// removed since). Lets a caller check "is this already local" without
    /// needing a session/connection/credentials at all — `SyncCoordinator
    /// .fetchRawSource` uses this to skip opening an IMAP connection
    /// entirely on a cache hit, so re-viewing an already-fetched message's
    /// source works even fully offline.
    public static func cachedURL(accountId: String, messageId: Int64) -> URL? {
        guard let url = try? storageURL(accountId: accountId, messageId: messageId),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Writes `data` directly to `messageId`'s cache path, bypassing any
    /// IMAP fetch entirely — for `AppEnvironment`'s `OTEGAMI_UITEST_INSERT_
    /// FAKE_HTML_MESSAGE` escape hatch (`scripts/verify-screen.sh`'s
    /// `message-source` scenario), the same "insert a fully local,
    /// already-fetched fake message" idea that fixture's `MessageBodyRecord
    /// .html`/`CalendarInviteSectionView`'s ICS-attachment fixture already
    /// use to get real content on screen without depending on this
    /// simulator/toolchain's unreliable IMAP connectivity (`docs/verify.md`).
    /// Not used by `fetchAndStore` itself — that one only ever writes bytes
    /// it just downloaded over a real session.
    @discardableResult
    public static func prewarmCache(accountId: String, messageId: Int64, data: Data) throws -> URL {
        let destination = try storageURL(accountId: accountId, messageId: messageId)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func storageURL(accountId: String, messageId: Int64) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("otegami", isDirectory: true)
            .appendingPathComponent("MessageSource", isDirectory: true)
            .appendingPathComponent(accountId, isDirectory: true)
        return directory.appendingPathComponent("\(messageId).eml")
    }
}
