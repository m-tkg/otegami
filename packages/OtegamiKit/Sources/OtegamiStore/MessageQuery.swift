import Foundation
import GRDB

/// Query helpers for `MessageRecord`, shared between one-shot fetches and
/// `ValueObservation`-driven live lists (`MessageListView`'s data source).
public enum MessageQuery {
    /// Messages in one mailbox, newest first. Sorted by `internalDate`
    /// (the server's receipt time — always present and monotonic with
    /// arrival) rather than the sender-supplied `date` header, which can be
    /// missing or backdated.
    public static func request(mailboxId: Int64) -> QueryInterfaceRequest<MessageRecord> {
        MessageRecord
            .filter(Column("mailboxId") == mailboxId)
            .order(Column("internalDate").desc, Column("uid").desc)
    }

    /// A `ValueObservation` that re-fetches ``request(mailboxId:)`` whenever
    /// the `message` table changes, for `MessageListView` to observe.
    public static func observation(mailboxId: Int64) -> ValueObservation<ValueReducers.Fetch<[MessageRecord]>> {
        ValueObservation.tracking { db in
            try request(mailboxId: mailboxId).fetchAll(db)
        }
    }

    /// The single highest UID currently stored for a mailbox, used by
    /// `AccountSyncer` to resume an incremental sync (`UID FETCH
    /// uidNext:*`, M3). `nil` for an empty (or never-synced) mailbox.
    public static func maxUID(mailboxId: Int64, db: Database) throws -> UInt32? {
        let value = try Int64.fetchOne(
            db,
            sql: "SELECT MAX(uid) FROM message WHERE mailboxId = ?",
            arguments: [mailboxId]
        )
        guard let value else { return nil }
        return UInt32(value)
    }
}

/// Query helpers for `MailboxRecord`.
public enum MailboxQuery {
    /// All mailboxes for one account, ordered for sidebar display: Inbox
    /// first, then other special-use roles, then everything else
    /// alphabetically by display path.
    public static func request(accountId: String) -> QueryInterfaceRequest<MailboxRecord> {
        MailboxRecord
            .filter(Column("accountId") == accountId)
            .order(
                (Column("role") == MailboxRoleRecord.inbox.rawValue).desc,
                Column("displayPath")
            )
    }

    public static func observation(accountId: String) -> ValueObservation<ValueReducers.Fetch<[MailboxRecord]>> {
        ValueObservation.tracking { db in
            try request(accountId: accountId).fetchAll(db)
        }
    }
}
