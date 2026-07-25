import Foundation
import GRDB
import OtegamiCore

/// Query helpers for `DraftMessageRecord` (M10): what the sidebar's "下書き"
/// row and `DraftsView` observe. Mirrors `OutboxQuery`'s shape.
public enum DraftQuery {
    public static func request(accountIds: [String]) -> QueryInterfaceRequest<DraftMessageRecord> {
        DraftMessageRecord
            .filter(accountIds.contains(Column("accountId")))
            .order(Column("updatedAt").desc)
    }

    public static func observation(accountIds: [String]) -> ValueObservation<ValueReducers.Fetch<[DraftMessageRecord]>> {
        ValueObservation.tracking { db in try request(accountIds: accountIds).fetchAll(db) }
    }

    /// Drafts IMAP sync: one row of the unified list `DraftsView` shows —
    /// either a local `draftMessage` row (`.local`) or a message living
    /// directly in a `MailboxRoleRecord.drafts` mailbox that no local row
    /// has ever claimed (`.server`) — see `DraftMessageRecord`'s doc
    /// comment for why a server-origin draft has no local row until it's
    /// actually edited and saved.
    public enum UnifiedRow: Sendable, Equatable, Identifiable {
        case local(DraftMessageRecord)
        /// `message`/`accountId`/`mailboxPath` — `mailboxPath` is what
        /// opening this draft's body/attachments over IMAP needs (the same
        /// "mailbox path, not just id" shape `MessageView`'s on-demand
        /// fetch already threads through).
        case server(message: MessageRecord, accountId: String, mailboxPath: String)

        public var id: String {
            switch self {
            case .local(let draft): "local-\(draft.id ?? 0)"
            case .server(let message, _, _): "server-\(message.id ?? 0)"
            }
        }

        public var accountId: String {
            switch self {
            case .local(let draft): draft.accountId
            case .server(_, let accountId, _): accountId
            }
        }

        public var subject: String {
            switch self {
            case .local(let draft): draft.subject
            case .server(let message, _, _): message.subject ?? ""
            }
        }

        public var toAddresses: [EmailAddress] {
            switch self {
            case .local(let draft): draft.toAddresses
            case .server(let message, _, _): message.toAddresses
            }
        }

        /// A short plain-text preview — `draft.plainTextBody` for a local
        /// row (always in memory, never lazily fetched), `message.snippet`
        /// for a server row (populated once its body has been fetched at
        /// least once, lazily on open like any other message; empty until
        /// then rather than triggering a network fetch just to render a
        /// list row).
        public var snippet: String {
            switch self {
            case .local(let draft): draft.plainTextBody.trimmingCharacters(in: .whitespacesAndNewlines)
            case .server(let message, _, _): message.snippet ?? ""
            }
        }

        public var updatedAt: Date {
            switch self {
            case .local(let draft): draft.updatedAt
            case .server(let message, _, _): message.internalDate
            }
        }
    }

    /// `DraftsView`'s single list: every local draft plus every
    /// server-origin one, newest-first. A server-origin `message` row is
    /// excluded once some local `draftMessage` row's `serverMailboxId`/
    /// `serverUid` already claims it — the row that's *about to replace* it
    /// (a pending `.saveDraft` op not yet replayed) or, on a
    /// UIDPLUS-supporting server, the row that already *did* replace it and
    /// is simply this same draft's local record from then on. Without this
    /// exclusion, a draft mid-edit would briefly appear twice: once as the
    /// local row being edited, once as the not-yet-superseded server copy.
    public static func unifiedRequest(accountIds: [String], db: Database) throws -> [UnifiedRow] {
        guard !accountIds.isEmpty else { return [] }

        let localDrafts = try request(accountIds: accountIds).fetchAll(db)
        let claimed = Set(localDrafts.compactMap { draft -> ServerRef? in
            guard let mailboxId = draft.serverMailboxId, let uid = draft.serverUid else { return nil }
            return ServerRef(mailboxId: mailboxId, uid: uid)
        })

        let draftsMailboxes = try MailboxRecord
            .filter(accountIds.contains(Column("accountId")))
            .filter(Column("role") == MailboxRoleRecord.drafts.rawValue)
            .fetchAll(db)

        var serverRows: [UnifiedRow] = []
        for mailbox in draftsMailboxes {
            guard let mailboxId = mailbox.id else { continue }
            let messages = try MessageRecord.filter(Column("mailboxId") == mailboxId).fetchAll(db)
            for message in messages where !claimed.contains(ServerRef(mailboxId: mailboxId, uid: message.uid)) {
                serverRows.append(.server(message: message, accountId: mailbox.accountId, mailboxPath: mailbox.path))
            }
        }

        let rows = localDrafts.map(UnifiedRow.local) + serverRows
        return rows.sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func unifiedObservation(accountIds: [String]) -> ValueObservation<ValueReducers.Fetch<[UnifiedRow]>> {
        ValueObservation.tracking { db in try unifiedRequest(accountIds: accountIds, db: db) }
    }

    private struct ServerRef: Hashable {
        var mailboxId: Int64
        var uid: Int64
    }
}
